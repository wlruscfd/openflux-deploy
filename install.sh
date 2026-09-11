#!/bin/bash
# OpenFlux control-plane auto-deployer.
#
# Run this directly ON the target VPS, as root (or via sudo):
#   curl -fsSL https://raw.githubusercontent.com/wlruscfd/openflux-deploy/main/install.sh -o install.sh
#   sudo bash install.sh
#
# It asks a handful of questions, then installs Postgres, Nginx, Go, builds
# and runs controlplane (see ../server/controlplane), and puts the admin
# panel behind HTTPS. Debian/Ubuntu only for this pass (anything with
# apt-get) - it exits early with a clear message on anything else rather
# than doing the wrong thing silently.
set -euo pipefail

GO_VERSION="1.26.5"
INSTALL_ROOT="/opt/openflux"
BIN_DIR="$INSTALL_ROOT/bin"
SRC_DIR="$INSTALL_ROOT/server"
ENV_FILE="/etc/openflux/controlplane.env"
SERVICE_NAME="openflux-controlplane"
SYSTEM_USER="openflux"
DEFAULT_REPO_URL="https://github.com/wlruscfd/openflux-server.git"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this as root (sudo bash install.sh)."
command -v apt-get >/dev/null 2>&1 || die "This script only supports Debian/Ubuntu (apt-get) right now."

# Reads VAR's value out of an already-written env file from a previous run,
# if any - lets a redeploy fall back to what's already there instead of
# generating a fresh value blind. Most critical for CONTROLPLANE_TOKEN_PEPPER
# below: every key/node/ingest-token secret is stored hashed with it, so a
# silently-regenerated pepper would make every one of them stop matching -
# not lost data exactly, but unusable, which is just as bad.
read_existing_env() {
    local var="$1"
    [ -f "$ENV_FILE" ] || return 0
    grep "^$var=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# ---------------------------------------------------------------------------
# $ENV_FILE only exists once a previous run has already gotten past the
# Postgres setup step (see below) - so if it's here, this is a redeploy, and
# there's an existing database worth protecting before touching anything.
# Cheap insurance: skipped entirely on a genuinely first install, where
# there's nothing yet to back up.
if [ -f "$ENV_FILE" ]; then
    BACKUP_DIR="/opt/openflux/backups/$(date +%Y%m%d-%H%M%S)"
    log "Existing install detected - backing up to $BACKUP_DIR before redeploying"
    mkdir -p "$BACKUP_DIR"
    if command -v pg_dump >/dev/null 2>&1 &&
        sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='openflux'" 2>/dev/null | grep -q 1; then
        sudo -u postgres pg_dump openflux > "$BACKUP_DIR/openflux.sql" ||
            warn "Database backup failed - continuing with the redeploy anyway."
    else
        warn "Postgres not found yet - nothing to back up despite $ENV_FILE existing."
    fi
    cp "$ENV_FILE" "$BACKUP_DIR/controlplane.env" 2>/dev/null || true
fi

ask() {
    # ask VAR "prompt" "default"
    # Skips the prompt entirely if VAR is already set in the environment -
    # this is what lets a caller (e.g. the Android app's SSH deployer)
    # drive this script non-interactively by pre-exporting every variable
    # it asks about, with zero changes to the interactive experience below.
    local __var="$1" __prompt="$2" __default="${3:-}" __reply
    if [ -n "${!__var:-}" ]; then
        return
    fi
    if [ -n "$__default" ]; then
        read -r -p "$__prompt [$__default]: " __reply || true
        __reply="${__reply:-$__default}"
    else
        read -r -p "$__prompt: " __reply || true
    fi
    printf -v "$__var" '%s' "$__reply"
}

ask_secret() {
    local __var="$1" __prompt="$2" __reply
    if [ -n "${!__var:-}" ]; then
        return
    fi
    read -r -s -p "$__prompt (leave blank to auto-generate): " __reply || true
    echo
    printf -v "$__var" '%s' "$__reply"
}

# ---------------------------------------------------------------------------
log "OpenFlux control-plane setup"
echo "Answer the questions below; press Enter to accept the default in [brackets]."

ask REPO_URL "openflux-server repo URL" "$DEFAULT_REPO_URL"
ask GIT_REF "Git branch/tag to deploy" "main"

ask TLS_MODE "TLS mode - 'domain' or 'ip'" "ip"
if [ "$TLS_MODE" = "domain" ]; then
    ask DOMAIN "Domain name pointing at this server's IP" ""
    [ -n "$DOMAIN" ] || die "A domain is required in domain mode."
    ask LE_EMAIL "Email for Let's Encrypt account/renewal notices" ""
    [ -n "$LE_EMAIL" ] || die "An email is required for Let's Encrypt registration."
    SERVER_NAME="$DOMAIN"
else
    DETECTED_IP="$(curl -fsS --max-time 5 https://ifconfig.me || true)"
    ask SERVER_IP "Public IP of this server" "$DETECTED_IP"
    [ -n "$SERVER_IP" ] || die "Could not detect the public IP automatically - enter it manually."
    SERVER_NAME="$SERVER_IP"
fi

ask_secret ADMIN_TOKEN "Admin panel token"
[ -n "$ADMIN_TOKEN" ] || ADMIN_TOKEN="$(read_existing_env CONTROLPLANE_ADMIN_TOKEN)"
[ -n "$ADMIN_TOKEN" ] || ADMIN_TOKEN="$(openssl rand -hex 32)"

ask_secret DB_PASSWORD "Postgres password for the openflux role"
[ -n "$DB_PASSWORD" ] || DB_PASSWORD="$(openssl rand -hex 24)"

# Unlike ADMIN_TOKEN/DB_PASSWORD there is no ask_secret prompt for this one -
# it's an internal hashing salt, not something anyone should be typing in by
# hand - so it must always come from the existing install if there is one.
# Every key/node/ingest-token secret is stored hashed with it; regenerating
# it on a redeploy would silently turn every previously issued one into a
# permanent mismatch (see read_existing_env's comment above).
TOKEN_PEPPER="$(read_existing_env CONTROLPLANE_TOKEN_PEPPER)"
[ -n "$TOKEN_PEPPER" ] || TOKEN_PEPPER="$(openssl rand -hex 32)"

ask REGISTER_NODE "Register a first exit node now? (y/n)" "y"
if [ "$REGISTER_NODE" = "y" ] || [ "$REGISTER_NODE" = "Y" ]; then
    ask NODE_NAME "First node's name" "node-1"
    ask NODE_MAX_KEYS "First node's max keys" "500"
fi

# ---------------------------------------------------------------------------
log "Installing packages (git, postgresql, nginx, snapd)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git curl postgresql nginx snapd openssl

# ---------------------------------------------------------------------------
# Debian/Ubuntu's apt-packaged certbot is years behind upstream (e.g. Ubuntu
# 24.04 ships 2.9.0) and doesn't know about IP-address certificates at all
# (--ip-address landed in certbot 5.3) - it rejects a bare IP outright
# ("will not issue certificates for a bare IP address") before ever asking
# Let's Encrypt. certbot's own snap is the officially recommended way to
# stay current, so that's what obtain_tls below relies on. If snap isn't
# usable on this host, this is deliberately non-fatal: obtain_tls will just
# fail to find certbot and the existing self-signed fallback takes over.
log "Installing certbot via snap"
if command -v snap >/dev/null 2>&1 &&
    snap wait system seed.loaded 2>/dev/null &&
    { snap install core >/dev/null 2>&1 || true; } &&
    { snap refresh core >/dev/null 2>&1 || true; } &&
    snap install --classic certbot; then
    ln -sf /snap/bin/certbot /usr/bin/certbot
else
    warn "Could not install certbot via snap (snap may not be usable on this host)."
    warn "TLS certificate issuance below will fail and fall back to a self-signed certificate."
fi

# ---------------------------------------------------------------------------
log "Installing Go $GO_VERSION (apt's Go is usually too old for this project)"
if ! command -v /usr/local/go/bin/go >/dev/null 2>&1 || \
   ! /usr/local/go/bin/go version | grep -q "go$GO_VERSION"; then
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64) GOARCH=amd64 ;;
        arm64) GOARCH=arm64 ;;
        *) die "Unsupported architecture: $ARCH" ;;
    esac
    TARBALL="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
    curl -fsSL "https://go.dev/dl/$TARBALL" -o "/tmp/$TARBALL"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/$TARBALL"
    rm -f "/tmp/$TARBALL"
fi
export PATH="/usr/local/go/bin:$PATH"

# ---------------------------------------------------------------------------
log "Fetching openflux-server ($GIT_REF)"
# Every run after the first sees $SRC_DIR owned by $SYSTEM_USER (the chown
# below applies to the whole $INSTALL_ROOT, .git included), while this
# script always runs as root - without this, git's dubious-ownership check
# refuses to touch a repo it doesn't own, breaking every redeploy after the
# first with "detected dubious ownership in repository".
git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$SRC_DIR" ||
    git config --global --add safe.directory "$SRC_DIR"
if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "$GIT_REF"
    git -C "$SRC_DIR" checkout "$GIT_REF"
    git -C "$SRC_DIR" reset --hard "origin/$GIT_REF"
else
    mkdir -p "$INSTALL_ROOT"
    git clone --branch "$GIT_REF" --depth 1 "$REPO_URL" "$SRC_DIR"
fi

log "Building controlplane"
mkdir -p "$BIN_DIR"
( cd "$SRC_DIR/controlplane" && go build -o "$BIN_DIR/controlplane" ./cmd/controlplane )

# ---------------------------------------------------------------------------
log "Setting up the openflux system user"
id -u "$SYSTEM_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SYSTEM_USER"
chown -R "$SYSTEM_USER:$SYSTEM_USER" "$INSTALL_ROOT"

# ---------------------------------------------------------------------------
log "Setting up Postgres"
DB_NAME="openflux"
DB_USER="openflux"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD';"
else
    sudo -u postgres psql -c "ALTER ROLE $DB_USER WITH PASSWORD '$DB_PASSWORD';"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
fi

DATABASE_URL="postgres://$DB_USER:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME?sslmode=disable"

# ---------------------------------------------------------------------------
log "Writing $ENV_FILE"
mkdir -p "$(dirname "$ENV_FILE")"
cat > "$ENV_FILE" <<EOF
CONTROLPLANE_DATABASE_URL=$DATABASE_URL
CONTROLPLANE_TOKEN_PEPPER=$TOKEN_PEPPER
CONTROLPLANE_ADMIN_TOKEN=$ADMIN_TOKEN
CONTROLPLANE_LISTEN_ADDR=127.0.0.1:8080
CONTROLPLANE_PUBLIC_URL=https://$SERVER_NAME
EOF
chown "$SYSTEM_USER:$SYSTEM_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------------------
# Templates below are inlined (not read from a sibling templates/ directory)
# because both documented ways of running this script - curl -o install.sh
# && bash install.sh, and the Android app's SSH deployer (see
# server/deployssh) - fetch only this one file, not the repo it lives in.
log "Installing the systemd service"
sed "s#/opt/openflux#$INSTALL_ROOT#g" <<'SERVICE_TEMPLATE' > "/etc/systemd/system/$SERVICE_NAME.service"
[Unit]
Description=OpenFlux control plane
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=openflux
Group=openflux
EnvironmentFile=/etc/openflux/controlplane.env
ExecStart=/opt/openflux/bin/controlplane
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/openflux
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE_TEMPLATE
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

log "Waiting for controlplane to come up"
for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1 || die "controlplane did not start - check: journalctl -u $SERVICE_NAME"

# ---------------------------------------------------------------------------
log "Configuring Nginx"
mkdir -p /var/www/certbot
sed "s/__SERVER_NAME__/$SERVER_NAME/g" <<'NGINX_INITIAL_TEMPLATE' > "/etc/nginx/sites-available/openflux"
# Written by install.sh. HTTP-only reverse proxy in front of controlplane,
# also serving Let's Encrypt's HTTP-01 challenge from /var/www/certbot -
# obtain_tls below needs that reachable before it runs. Domain mode's
# certbot --nginx plugin rewrites this into an HTTPS block itself; IP mode
# (and the self-signed fallback) get a hand-written one - see obtain_tls
# and write_https_nginx_config.
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAME__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_INITIAL_TEMPLATE
ln -sf /etc/nginx/sites-available/openflux /etc/nginx/sites-enabled/openflux
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# Writes the HTTPS vhost for an already-obtained cert/key pair and reloads
# Nginx. Used for IP-mode certificates and the self-signed fallback - NOT
# for domain mode, where certbot's own --nginx plugin edits Nginx itself
# (mature, auto-installs and renews on its own; see obtain_tls). The
# acme-challenge location is kept even after moving to HTTPS so a future
# webroot-based renewal (IP mode) keeps working without editing this again.
write_https_nginx_config() {
    local cert="$1" key="$2"
    sed -e "s/__SERVER_NAME__/$SERVER_NAME/g" \
        -e "s#__CERT_PATH__#$cert#g" \
        -e "s#__KEY_PATH__#$key#g" <<'NGINX_HTTPS_TEMPLATE' > /etc/nginx/sites-available/openflux
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAME__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name __SERVER_NAME__;

    ssl_certificate __CERT_PATH__;
    ssl_certificate_key __KEY_PATH__;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_HTTPS_TEMPLATE
    nginx -t
    systemctl reload nginx
}

# Requests a certificate for $SERVER_NAME. Domain mode uses certbot's own
# nginx plugin (mature, auto-edits/reloads Nginx and renews itself). IP mode
# uses Let's Encrypt's newer short-lived-certificate-for-IP-address
# capability, which as of certbot 5.x only supports the webroot plugin and
# doesn't auto-install into a web server yet - write_https_nginx_config
# does that part by hand. On any failure this falls back to a self-signed
# certificate instead of leaving the panel on plain HTTP or aborting.
obtain_tls() {
    if [ "$TLS_MODE" = "domain" ]; then
        certbot --nginx --non-interactive --agree-tos -m "$LE_EMAIL" -d "$SERVER_NAME" --redirect
        return $?
    fi

    log "Attempting Let's Encrypt short-lived certificate for IP $SERVER_NAME"
    # IP mode never prompts for an email (see ask() above), but the ACME
    # server still validates whatever address it's given - a made-up
    # address under the reserved .invalid TLD (RFC 2606) used to be passed
    # here and was rejected outright ("believes ... is an invalid email
    # address"). Falls back to a random mailbox on a real, resolvable
    # domain instead when the caller didn't supply LE_EMAIL.
    local ip_mode_email="${LE_EMAIL:-$(openssl rand -hex 6)@helloo.lol}"
    if certbot certonly --webroot --webroot-path /var/www/certbot --non-interactive --agree-tos \
        -m "$ip_mode_email" \
        --preferred-profile shortlived --ip-address "$SERVER_NAME"; then
        write_https_nginx_config "/etc/letsencrypt/live/$SERVER_NAME/fullchain.pem" \
            "/etc/letsencrypt/live/$SERVER_NAME/privkey.pem"
        return 0
    fi
    return 1
}

log "Requesting a TLS certificate ($TLS_MODE mode)"
if obtain_tls; then
    log "TLS certificate installed via Let's Encrypt"
    if [ "$TLS_MODE" = "ip" ]; then
        warn "This is a short-lived (~6 day) IP certificate. certbot's own automatic renewal" \
             "(enabled by its snap package) renews it well before expiry on its regular check."
    fi
else
    warn "Automated Let's Encrypt issuance for $SERVER_NAME failed."
    warn "Falling back to a self-signed certificate so the panel is still reachable over HTTPS."
    warn "Browsers will show a certificate warning until you either retry with a working" \
         "domain, or replace the cert at /etc/openflux/tls yourself."
    mkdir -p /etc/openflux/tls
    openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
        -keyout /etc/openflux/tls/selfsigned.key \
        -out /etc/openflux/tls/selfsigned.crt \
        -subj "/CN=$SERVER_NAME" \
        -addext "subjectAltName=IP:$SERVER_NAME" 2>/dev/null || \
    openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
        -keyout /etc/openflux/tls/selfsigned.key \
        -out /etc/openflux/tls/selfsigned.crt \
        -subj "/CN=$SERVER_NAME"
    write_https_nginx_config /etc/openflux/tls/selfsigned.crt /etc/openflux/tls/selfsigned.key
fi

# ---------------------------------------------------------------------------
NODE_TOKEN=""
NODE_ID=""
if [ "${REGISTER_NODE:-n}" = "y" ] || [ "${REGISTER_NODE:-n}" = "Y" ]; then
    # REGISTER_NODE=y is the app's default on every deploy, including
    # redeploys of an already-registered server - without this check, each
    # one would register a brand new duplicate node (same name, new id),
    # leaving the old one's token orphaned instead of touching anything.
    EXISTING_NODES="$(curl -fsS "http://127.0.0.1:8080/v1/admin/nodes" \
        -H "Authorization: Bearer $ADMIN_TOKEN")" || EXISTING_NODES=""
    if printf '%s' "$EXISTING_NODES" | grep -qF "\"Name\":\"$NODE_NAME\""; then
        log "Node \"$NODE_NAME\" is already registered - leaving it as is"
        warn "Its token was only shown once, at creation. Use the admin panel's" \
             "\"rotate token\" button if you've lost it."
    else
        log "Registering the first exit node"
        NODE_JSON="$(curl -fsS -X POST "http://127.0.0.1:8080/v1/admin/nodes" \
            -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
            -d "{\"name\":\"$NODE_NAME\",\"max_keys\":$NODE_MAX_KEYS}")" || warn "Node registration failed - you can create one later from the admin panel."
        if [ -n "${NODE_JSON:-}" ]; then
            NODE_TOKEN="$(printf '%s' "$NODE_JSON" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)"
            NODE_ID="$(printf '%s' "$NODE_JSON" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
PANEL_URL="https://$SERVER_NAME/admin/"
log "Done"
cat <<SUMMARY

  Panel URL:     $PANEL_URL
  Admin token:   $ADMIN_TOKEN
  (save the admin token now - it is only stored, hashed, in Postgres and
  cannot be recovered from the server afterwards)

SUMMARY

if [ -n "$NODE_TOKEN" ]; then
cat <<NODESUMMARY
  First node ID:     $NODE_ID
  First node token:  $NODE_TOKEN

  On the exit-node machine:
    ./universal-bypass-tool --exit-node --managed \\
        --control-url "https://$SERVER_NAME" \\
        --node-token "$NODE_TOKEN"

NODESUMMARY
fi

echo "Re-run this script any time to redeploy a newer --git-ref of openflux-server."

# One machine-readable line for automated callers (e.g. the app's SSH
# deployer) to parse - see server/deployssh's resultLinePrefix. Harmless
# to ignore if you're reading this as a human; everything in it is already
# in the summary above.
echo "OPENFLUX_DEPLOY_RESULT panel_url=$PANEL_URL admin_token=$ADMIN_TOKEN node_token=${NODE_TOKEN:-}"
