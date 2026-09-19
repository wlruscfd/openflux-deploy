#!/bin/bash
# OpenFlux control-plane auto-deployer - run as root on the target VPS: curl -fsSL .../install.sh -o install.sh && sudo bash install.sh
set -euo pipefail

GO_VERSION="1.26.5"
INSTALL_ROOT="/opt/openflux"
BIN_DIR="$INSTALL_ROOT/bin"
SRC_DIR="$INSTALL_ROOT/server"
ENV_FILE="/etc/openflux/controlplane.env"
NODEAGENT_ENV_FILE="/etc/openflux/nodeagent.env"
# Under /etc/openflux, not /etc/nginx/conf.d/ - a bare location{} block there is a syntax error outside server{}.
NGINX_LOCATIONS_FILE="/etc/openflux/nginx-locations.conf"
SERVICE_NAME="openflux-controlplane"
NODEAGENT_SERVICE_NAME="openflux-nodeagent"
WEB_SERVICE_NAME="openflux-web"
WEB_ENV_FILE="/etc/openflux/web.env"
SYSTEM_USER="openflux"
DEFAULT_REPO_URL="https://github.com/wlruscfd/openflux-server.git"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this as root (sudo bash install.sh)."

if command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY="debian"
elif command -v dnf >/dev/null 2>&1; then
    OS_FAMILY="rhel"
else
    die "This script only supports Debian/Ubuntu (apt-get) or AlmaLinux/RHEL-family (dnf) right now."
fi

# Lets a redeploy reuse a value from a previous run (e.g. CONTROLPLANE_TOKEN_PEPPER) instead of generating a fresh one blind.
read_existing_env() {
    local var="$1" file="${2:-$ENV_FILE}"
    [ -f "$file" ] || return 0
    grep "^$var=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# Back up the DB before a redeploy touches anything; skipped on a first install, where there's nothing yet.
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
    # ask VAR "prompt" "default" - skips the prompt if VAR is already set (lets a caller pre-export answers non-interactively).
    local __var="$1" __prompt="$2" __default="${3:-}" __reply
    if [ -n "${!__var:-}" ]; then
        return
    fi
    # Reads from /dev/tty (curl|bash makes stdin the script itself) and prints the prompt by hand (bash's -p misdetects the tty here).
    if [ -n "$__default" ]; then
        printf '%s [%s]: ' "$__prompt" "$__default" > /dev/tty 2>/dev/null || true
    else
        printf '%s: ' "$__prompt" > /dev/tty 2>/dev/null || true
    fi
    read -r __reply < /dev/tty 2>/dev/null || true
    [ -n "$__default" ] && __reply="${__reply:-$__default}"
    printf -v "$__var" '%s' "$__reply"
}

ask_secret() {
    local __var="$1" __prompt="$2" __reply
    if [ -n "${!__var:-}" ]; then
        return
    fi
    printf '%s (leave blank to auto-generate): ' "$__prompt" > /dev/tty 2>/dev/null || true
    read -r -s __reply < /dev/tty 2>/dev/null || true
    echo > /dev/tty 2>/dev/null || true
    printf -v "$__var" '%s' "$__reply"
}

log "OpenFlux control-plane setup"
echo "Answer the questions below; press Enter to accept the default in [brackets]."

ask REPO_URL "openflux-server repo URL" "$DEFAULT_REPO_URL"
ask GIT_REF "Git branch/tag to deploy" "main"

echo
echo "Before you continue: your VPS/cloud firewall (security group) needs to allow"
echo "inbound TCP 443 for 'domain'/'ip' mode below (443 is just the default and can be"
echo "changed in a moment if it's already taken; plus TCP 80 too if you want normal"
echo "Let's Encrypt renewal instead of the default self-signed cert - see the next"
echo "few questions), or TCP 8080 for 'http' mode - whichever you pick, that port has"
echo "to be reachable from the internet or nothing past this point will actually work."
echo

ask TLS_MODE "TLS mode - 'domain', 'ip', or 'http' (no panel/TLS - manage only via the app)" "ip"
if [ "$TLS_MODE" = "domain" ]; then
    ask DOMAIN "Domain name pointing at this server's IP" ""
    [ -n "$DOMAIN" ] || die "A domain is required in domain mode."
    ask LE_EMAIL "Email for Let's Encrypt account/renewal notices" ""
    [ -n "$LE_EMAIL" ] || die "An email is required for Let's Encrypt registration."
    SERVER_NAME="$DOMAIN"
    ask HTTPS_PORT "HTTPS port for the panel (change only if 443 is already used by something else on this server)" "443"
elif [ "$TLS_MODE" = "http" ]; then
    DETECTED_IP="$(curl -fsS --max-time 5 https://ifconfig.me || true)"
    ask SERVER_IP "Public IP of this server" "$DETECTED_IP"
    [ -n "$SERVER_IP" ] || die "Could not detect the public IP automatically - enter it manually."
    SERVER_NAME="$SERVER_IP"
    warn "http mode: the admin API will be served in PLAIN HTTP on port 8080, with no" \
         "Nginx or TLS in front of it at all - anyone on the network path (your ISP, the" \
         "VPS host's network, a coffee-shop Wi-Fi) can read the admin token and every" \
         "request in transit. Only pick this if you're managing everything from the app" \
         "and understand that tradeoff; 'ip' mode costs nothing extra and keeps the panel" \
         "on HTTPS instead."
else
    DETECTED_IP="$(curl -fsS --max-time 5 https://ifconfig.me || true)"
    ask SERVER_IP "Public IP of this server" "$DETECTED_IP"
    [ -n "$SERVER_IP" ] || die "Could not detect the public IP automatically - enter it manually."
    SERVER_NAME="$SERVER_IP"
    ask HTTPS_PORT "HTTPS port for the panel (change only if 443 is already used by something else on this server)" "443"
fi
HTTPS_PORT="${HTTPS_PORT:-443}"

if [ "$TLS_MODE" != "http" ]; then
    ask RESERVE_PORT_80 "Reserve port 80 for another service on this machine? Skips Let's Encrypt entirely (self-signed cert on \$HTTPS_PORT only, no auto-renewal) (y/n)" "n"
fi

ask WEB_PANEL "Install the SvelteKit web panel (Bun)? (y/n)" "y"

# AlmaLinux/RHEL-family ships firewalld active by default (Debian/Ubuntu doesn't) - without this it'd still block everything.
if [ "$OS_FAMILY" = "rhel" ] && command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "Opening the needed port(s) in firewalld"
    if [ "$TLS_MODE" = "http" ]; then
        case "${WEB_PANEL:-n}" in
            y|Y) firewall-cmd --permanent --add-port=3000/tcp ;;
            *)   firewall-cmd --permanent --add-port=8080/tcp ;;
        esac
    elif [ "${RESERVE_PORT_80:-n}" = "y" ] || [ "${RESERVE_PORT_80:-n}" = "Y" ]; then
        firewall-cmd --permanent --add-port="$HTTPS_PORT/tcp"
    else
        firewall-cmd --permanent --add-service=http --add-port="$HTTPS_PORT/tcp"
    fi
    firewall-cmd --reload
fi

ask_secret ADMIN_TOKEN "Admin panel token"
[ -n "$ADMIN_TOKEN" ] || ADMIN_TOKEN="$(read_existing_env CONTROLPLANE_ADMIN_TOKEN)"
[ -n "$ADMIN_TOKEN" ] || ADMIN_TOKEN="$(openssl rand -hex 32)"

ask_secret DB_PASSWORD "Postgres password for the openflux role"
[ -n "$DB_PASSWORD" ] || DB_PASSWORD="$(openssl rand -hex 24)"

# Internal hashing salt, not user-facing - must come from the existing install if there is one (see read_existing_env).
TOKEN_PEPPER="$(read_existing_env CONTROLPLANE_TOKEN_PEPPER)"
[ -n "$TOKEN_PEPPER" ] || TOKEN_PEPPER="$(openssl rand -hex 32)"

ask REGISTER_NODE "Register a first exit node now? (y/n)" "y"
if [ "$REGISTER_NODE" = "y" ] || [ "$REGISTER_NODE" = "Y" ]; then
    ask NODE_NAME "First node's name" "node-1"
    ask NODE_MAX_KEYS "First node's max keys" "500"
    ask RUN_NODE_HERE "Also run this exit node on this same server? (y/n)" "y"
fi

if [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    if [ "$TLS_MODE" = "http" ]; then
        log "Installing packages (git, postgresql)"
        apt-get install -y git curl postgresql postgresql-contrib openssl unzip
    else
        log "Installing packages (git, postgresql, nginx, snapd)"
        apt-get install -y git curl postgresql postgresql-contrib nginx snapd openssl unzip
    fi
else
    if [ "$TLS_MODE" = "http" ]; then
        log "Installing packages (git, postgresql)"
        dnf install -y git curl postgresql-server postgresql postgresql-contrib openssl iptables-nft unzip
    else
        log "Installing packages (git, postgresql, nginx, snapd)"
        dnf install -y epel-release
        dnf install -y git curl postgresql-server postgresql postgresql-contrib nginx snapd openssl iptables-nft unzip policycoreutils-python-utils
        systemctl enable --now snapd.socket
        ln -sf /var/lib/snapd/snap /snap
    fi
fi

if [ "$TLS_MODE" != "http" ] && [ "${RESERVE_PORT_80:-n}" != "y" ] && [ "${RESERVE_PORT_80:-n}" != "Y" ]; then
    # Distro-packaged certbot is too old for IP-address certs (needs 5.3+) - certbot's own snap stays current.
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
fi

log "Installing Go $GO_VERSION (apt's Go is usually too old for this project)"
if ! command -v /usr/local/go/bin/go >/dev/null 2>&1 || \
   ! /usr/local/go/bin/go version | grep -q "go$GO_VERSION"; then
    if command -v dpkg >/dev/null 2>&1; then
        ARCH="$(dpkg --print-architecture)"
    else
        case "$(uname -m)" in
            x86_64) ARCH=amd64 ;;
            aarch64) ARCH=arm64 ;;
            *) ARCH="$(uname -m)" ;;
        esac
    fi
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

log "Fetching openflux-server ($GIT_REF)"
# Needed once $SRC_DIR is owned by $SYSTEM_USER (see chown below) - git refuses a repo it doesn't own otherwise.
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

if [ "${RUN_NODE_HERE:-n}" = "y" ] || [ "${RUN_NODE_HERE:-n}" = "Y" ]; then
    log "Building the exit-node binary"
    ( cd "$SRC_DIR" && go build -o "$BIN_DIR/universal-bypass-tool" . )
fi

# Optional: controlplane always serves its own embedded panel at /admin/ regardless (see admin.html).
WEB_BUN="${WEB_BUN:-}"
if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
    log "Setting up Bun (for the SvelteKit web panel)"
    BUN_INSTALL_DIR="$INSTALL_ROOT/bun"
    if [ -x "$BUN_INSTALL_DIR/bin/bun" ]; then
        WEB_BUN="$BUN_INSTALL_DIR/bin/bun"
    else
        WEB_BUN="$(command -v bun || true)"
        case "$WEB_BUN" in
            /root/*|/home/*)
                # Invisible inside the web-panel service's ProtectHome=true sandbox - treat as absent.
                WEB_BUN=""
                ;;
        esac
    fi
    if [ -z "$WEB_BUN" ]; then
        # export inside (...) scopes BUN_INSTALL to bun's own install pipeline without leaking it further.
        if (export BUN_INSTALL="$BUN_INSTALL_DIR"; curl -fsSL https://bun.sh/install | bash) &&
            [ -x "$BUN_INSTALL_DIR/bin/bun" ]; then
            WEB_BUN="$BUN_INSTALL_DIR/bin/bun"
        else
            warn "Bun install failed - falling back to controlplane's embedded panel."
            WEB_PANEL="n"
        fi
    fi
fi
if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
    log "Building the SvelteKit web panel"
    WEB_DIR="$INSTALL_ROOT/web"
    # node_modules ships alongside build/ - adapter-node's handler.js needs it resolvable from $WEB_DIR at runtime.
    # Staged into $WEB_DIR.new and swapped in only once every step succeeds, so a failure partway through never leaves a mismatched build/+node_modules live.
    WEB_DIR_NEW="$WEB_DIR.new"
    WEB_DIR_OLD="$WEB_DIR.old"
    rm -rf "$WEB_DIR_NEW"
    if ( cd "$SRC_DIR/controlplane/web" \
        && "$WEB_BUN" install \
        && "$WEB_BUN" run build \
        && mkdir -p "$WEB_DIR_NEW" \
        && cp -a build "$WEB_DIR_NEW/" \
        && cp -a node_modules "$WEB_DIR_NEW/" \
        && cp package.json server.js "$WEB_DIR_NEW/" ); then
        rm -rf "$WEB_DIR_OLD"
        # Not `[ -d "$WEB_DIR" ] && mv ...` - under set -e a false test here would abort the script.
        if [ -d "$WEB_DIR" ]; then
            mv "$WEB_DIR" "$WEB_DIR_OLD"
        fi
        mv "$WEB_DIR_NEW" "$WEB_DIR"
        rm -rf "$WEB_DIR_OLD"
        log "Web panel built to $WEB_DIR"
    else
        warn "Web panel build failed - falling back to controlplane's embedded panel."
        rm -rf "$WEB_DIR_NEW"
        WEB_PANEL="n"
    fi
fi

log "Setting up the openflux system user"
id -u "$SYSTEM_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SYSTEM_USER"
chown -R "$SYSTEM_USER:$SYSTEM_USER" "$INSTALL_ROOT"

log "Setting up Postgres"
if [ "$OS_FAMILY" = "rhel" ]; then
    # dnf's postgresql-server doesn't init/start itself the way Debian's postgresql package does.
    find_pg_datadir() {
        if [ -d /var/lib/pgsql/data ]; then
            echo /var/lib/pgsql/data
        else
            ls -d /var/lib/pgsql/*/data 2>/dev/null | head -n1
        fi
    }
    PG_DATADIR="$(find_pg_datadir)"
    if [ -z "$PG_DATADIR" ] || [ ! -f "$PG_DATADIR/PG_VERSION" ]; then
        postgresql-setup --initdb
        PG_DATADIR="$(find_pg_datadir)"
    fi
    # RHEL-family's default pg_hba.conf uses "ident" for local TCP, which rejects the password auth DATABASE_URL needs.
    if [ -n "$PG_DATADIR" ] && [ -f "$PG_DATADIR/pg_hba.conf" ]; then
        sed -i -E 's/^(host +all +all +127\.0\.0\.1\/32 +)ident/\1scram-sha-256/' "$PG_DATADIR/pg_hba.conf"
        sed -i -E 's/^(host +all +all +::1\/128 +)ident/\1scram-sha-256/' "$PG_DATADIR/pg_hba.conf"
    fi
    systemctl enable --now postgresql
    systemctl reload postgresql 2>/dev/null || systemctl restart postgresql
fi
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

log "Writing $ENV_FILE"
mkdir -p "$(dirname "$ENV_FILE")"
# ip/domain mode: Nginx fronts both services, controlplane stays on loopback. http mode: web panel (if any) is the public origin instead.
WEB_HOST="127.0.0.1"
WEB_PORT="3000"
if [ "$TLS_MODE" = "http" ]; then
    if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
        CONTROLPLANE_LISTEN_ADDR="127.0.0.1:8080"
        CONTROLPLANE_PUBLIC_URL="http://$SERVER_NAME:3000"
        WEB_HOST="0.0.0.0"
    else
        CONTROLPLANE_LISTEN_ADDR="0.0.0.0:8080"
        CONTROLPLANE_PUBLIC_URL="http://$SERVER_NAME:8080"
    fi
else
    CONTROLPLANE_LISTEN_ADDR="127.0.0.1:8080"
    if [ "$HTTPS_PORT" = "443" ]; then
        CONTROLPLANE_PUBLIC_URL="https://$SERVER_NAME"
    else
        CONTROLPLANE_PUBLIC_URL="https://$SERVER_NAME:$HTTPS_PORT"
    fi
fi
cat > "$ENV_FILE" <<EOF
CONTROLPLANE_DATABASE_URL=$DATABASE_URL
CONTROLPLANE_TOKEN_PEPPER=$TOKEN_PEPPER
CONTROLPLANE_ADMIN_TOKEN=$ADMIN_TOKEN
CONTROLPLANE_LISTEN_ADDR=$CONTROLPLANE_LISTEN_ADDR
CONTROLPLANE_PUBLIC_URL=$CONTROLPLANE_PUBLIC_URL
EOF
chown "$SYSTEM_USER:$SYSTEM_USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
    cat > "$WEB_ENV_FILE" <<EOF
CONTROLPLANE_UPSTREAM=http://127.0.0.1:8080
CONTROLPLANE_WEB_HOST=$WEB_HOST
CONTROLPLANE_WEB_PORT=$WEB_PORT
EOF
    chown "$SYSTEM_USER:$SYSTEM_USER" "$WEB_ENV_FILE"
    chmod 600 "$WEB_ENV_FILE"
fi

# Templates are inlined, not read from a sibling file - both `curl -o install.sh` and the app's SSH deployer fetch only this one file.
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
LimitNOFILE=65535
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/openflux
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE_TEMPLATE
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
# restart, not enable --now - a bare `start` on an already-running service would keep the old binary/env alive across a redeploy.
systemctl restart "$SERVICE_NAME"

if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
    log "Installing the web panel systemd service"
    [ -n "$WEB_BUN" ] || WEB_BUN="$(command -v bun || echo /opt/openflux/bun/bin/bun)"
    sed -e "s#/opt/openflux#$INSTALL_ROOT#g" \
        -e "s#__WEB_BUN__#$WEB_BUN#g" \
        -e "s#__CONTROLPLANE_SERVICE__#$SERVICE_NAME#g" \
        <<'WEB_SERVICE_TEMPLATE' > "/etc/systemd/system/$WEB_SERVICE_NAME.service"
[Unit]
Description=OpenFlux control-plane web panel (SvelteKit)
After=network.target __CONTROLPLANE_SERVICE__.service
Wants=__CONTROLPLANE_SERVICE__.service

[Service]
Type=simple
User=openflux
Group=openflux
WorkingDirectory=/opt/openflux/web
EnvironmentFile=/etc/openflux/web.env
ExecStart=__WEB_BUN__ server.js
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/openflux
PrivateTmp=true

[Install]
WantedBy=multi-user.target
WEB_SERVICE_TEMPLATE
    systemctl daemon-reload
    systemctl enable "$WEB_SERVICE_NAME"
    systemctl restart "$WEB_SERVICE_NAME"
fi

log "Waiting for controlplane to come up"
for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://127.0.0.1:8080/healthz" >/dev/null 2>&1 || die "controlplane did not start - check: journalctl -u $SERVICE_NAME"

if [ "$TLS_MODE" != "http" ]; then

log "Configuring Nginx"
# SELinux (RHEL-family) blocks Nginx from proxying out by default - without this every proxy_pass below would 502.
if [ "$OS_FAMILY" = "rhel" ] && command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
fi
systemctl enable --now nginx
mkdir -p /var/www/certbot /etc/nginx/conf.d
# Shared by both vhost templates below; routes /admin/ to the web panel (if any), everything else to controlplane.
write_web_locations() {
    mkdir -p "$(dirname "$NGINX_LOCATIONS_FILE")"
    if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
        cat > "$NGINX_LOCATIONS_FILE" <<'WEB_LOCS'
    location /healthz {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }

    location /v1/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /admin/ {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        return 404;
    }
WEB_LOCS
    else
        cat > "$NGINX_LOCATIONS_FILE" <<'WEB_LOCS'
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
WEB_LOCS
    fi
}
write_web_locations
# Needs the SELinux httpd_config_t label on RHEL-family, or nginx -t fails reading it ("Permission denied").
if [ "$OS_FAMILY" = "rhel" ] && command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t httpd_config_t "$NGINX_LOCATIONS_FILE" 2>/dev/null \
        || semanage fcontext -m -t httpd_config_t "$NGINX_LOCATIONS_FILE" 2>/dev/null || true
    command -v restorecon >/dev/null 2>&1 && restorecon "$NGINX_LOCATIONS_FILE" 2>/dev/null || true
fi
# Removes stock default vhosts and this script's own pre-conf.d leftovers - needed even when reserving port 80, since nginx's own untouched default vhost also listens on it.
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
rm -f /etc/nginx/sites-enabled/openflux /etc/nginx/sites-available/openflux
rm -f /etc/nginx/conf.d/openflux-locations.conf

# Used for IP-mode certs and the self-signed fallback; domain mode's certbot --nginx plugin edits Nginx itself instead. Drops the port-80 block entirely when RESERVE_PORT_80 claims it for another service.
write_https_nginx_config() {
    local cert="$1" key="$2"
    local redirect_port_suffix=""
    [ "$HTTPS_PORT" = "443" ] || redirect_port_suffix=":$HTTPS_PORT"
    if [ "${RESERVE_PORT_80:-n}" = "y" ] || [ "${RESERVE_PORT_80:-n}" = "Y" ]; then
        sed -e "s/__SERVER_NAME__/$SERVER_NAME/g" \
            -e "s#__CERT_PATH__#$cert#g" \
            -e "s#__KEY_PATH__#$key#g" \
            -e "s/__HTTPS_PORT__/$HTTPS_PORT/g" \
            -e "s#__NGINX_LOCATIONS_FILE__#$NGINX_LOCATIONS_FILE#g" <<'NGINX_HTTPS_ONLY_TEMPLATE' > /etc/nginx/conf.d/openflux.conf
server {
    listen __HTTPS_PORT__ ssl;
    listen [::]:__HTTPS_PORT__ ssl;
    server_name __SERVER_NAME__;

    ssl_certificate __CERT_PATH__;
    ssl_certificate_key __KEY_PATH__;

    include __NGINX_LOCATIONS_FILE__;
}
NGINX_HTTPS_ONLY_TEMPLATE
    else
        sed -e "s/__SERVER_NAME__/$SERVER_NAME/g" \
            -e "s#__CERT_PATH__#$cert#g" \
            -e "s#__KEY_PATH__#$key#g" \
            -e "s/__HTTPS_PORT__/$HTTPS_PORT/g" \
            -e "s/__REDIRECT_PORT_SUFFIX__/$redirect_port_suffix/g" \
            -e "s#__NGINX_LOCATIONS_FILE__#$NGINX_LOCATIONS_FILE#g" <<'NGINX_HTTPS_TEMPLATE' > /etc/nginx/conf.d/openflux.conf
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAME__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host__REDIRECT_PORT_SUFFIX__$request_uri;
    }
}

server {
    listen __HTTPS_PORT__ ssl;
    listen [::]:__HTTPS_PORT__ ssl;
    server_name __SERVER_NAME__;

    ssl_certificate __CERT_PATH__;
    ssl_certificate_key __KEY_PATH__;

    include __NGINX_LOCATIONS_FILE__;
}
NGINX_HTTPS_TEMPLATE
    fi
    nginx -t
    systemctl reload nginx
}

if [ "${RESERVE_PORT_80:-n}" = "y" ] || [ "${RESERVE_PORT_80:-n}" = "Y" ]; then
    log "Reserving port 80 for another service - using a self-signed certificate, no Let's Encrypt"
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
else

sed -e "s/__SERVER_NAME__/$SERVER_NAME/g" -e "s#__NGINX_LOCATIONS_FILE__#$NGINX_LOCATIONS_FILE#g" <<'NGINX_INITIAL_TEMPLATE' > "/etc/nginx/conf.d/openflux.conf"
# Written by install.sh.
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAME__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    include __NGINX_LOCATIONS_FILE__;
}
NGINX_INITIAL_TEMPLATE
nginx -t
systemctl reload nginx

# Domain mode uses certbot's --nginx plugin; IP mode uses its short-lived-IP-cert capability, hand-installed via write_https_nginx_config.
obtain_tls() {
    if [ "$TLS_MODE" = "domain" ]; then
        local https_port_flag=""
        [ "$HTTPS_PORT" = "443" ] || https_port_flag="--https-port $HTTPS_PORT"
        certbot --nginx --non-interactive --agree-tos -m "$LE_EMAIL" -d "$SERVER_NAME" --redirect $https_port_flag
        return $?
    fi

    log "Attempting Let's Encrypt short-lived certificate for IP $SERVER_NAME"
    # ACME rejects a made-up address under .invalid, so fall back to a random mailbox on a real domain instead.
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

fi

else
    log "http mode: skipping Nginx/TLS - controlplane is reachable directly on $CONTROLPLANE_PUBLIC_URL"
fi

NODE_TOKEN="${NODE_TOKEN:-}"
NODE_ID=""
if [ "${REGISTER_NODE:-n}" = "y" ] || [ "${REGISTER_NODE:-n}" = "Y" ]; then
    # Avoids registering a duplicate node on every redeploy of an already-registered server.
    EXISTING_NODES="$(curl -fsS "http://127.0.0.1:8080/v1/admin/nodes" \
        -H "Authorization: Bearer $ADMIN_TOKEN")" || EXISTING_NODES=""
    if printf '%s' "$EXISTING_NODES" | grep -qF "\"Name\":\"$NODE_NAME\""; then
        log "Node \"$NODE_NAME\" is already registered - leaving it as is"
        # A node's token is one-way hashed, same as any other - a redeploy can only reuse a previously saved copy.
        NODE_TOKEN="${NODE_TOKEN:-$(read_existing_env NODEAGENT_TOKEN "$NODEAGENT_ENV_FILE")}"
        NODE_ID="$(printf '%s' "$EXISTING_NODES" | grep -o "\"ID\":\"[^\"]*\",\"Name\":\"$NODE_NAME\"" | grep -o '"ID":"[^"]*"' | cut -d'"' -f4 | head -n1)"
        if [ -z "$NODE_TOKEN" ]; then
            warn "Its token was only shown once, at creation, and isn't saved on this" \
                 "server either - use the admin panel's \"rotate token\" button, then" \
                 "re-run with NODE_TOKEN=<that token> bash install.sh"
        fi
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

NODE_RUNNING_HERE="n"
if { [ "${RUN_NODE_HERE:-n}" = "y" ] || [ "${RUN_NODE_HERE:-n}" = "Y" ]; } && [ -n "$NODE_TOKEN" ]; then
    log "Setting up the exit node on this server"

    # The kernel would otherwise RST/ICMP-unreachable the raw socket's own TCP/UDP traffic, since it owns no socket for it.
    iptables -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || \
        iptables -A OUTPUT -p tcp --tcp-flags RST RST -j DROP

    iptables -C OUTPUT -p icmp --icmp-type port-unreachable -j DROP 2>/dev/null || \
        iptables -A OUTPUT -p icmp --icmp-type port-unreachable -j DROP

    mkdir -p "$(dirname "$NODEAGENT_ENV_FILE")"
    cat > "$NODEAGENT_ENV_FILE" <<EOF
NODEAGENT_CONTROL_URL=http://127.0.0.1:8080
NODEAGENT_TOKEN=$NODE_TOKEN
EOF
    chmod 600 "$NODEAGENT_ENV_FILE"

    sed "s#/opt/openflux#$INSTALL_ROOT#g" <<'NODEAGENT_SERVICE_TEMPLATE' > "/etc/systemd/system/$NODEAGENT_SERVICE_NAME.service"
[Unit]
Description=OpenFlux exit node
After=network.target openflux-controlplane.service
Wants=openflux-controlplane.service

[Service]
Type=simple
EnvironmentFile=/etc/openflux/nodeagent.env
ExecStart=/opt/openflux/bin/universal-bypass-tool --exit-node --managed --control-url ${NODEAGENT_CONTROL_URL} --node-token ${NODEAGENT_TOKEN}
Restart=on-failure
RestartSec=2
LimitNOFILE=524288
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
NODEAGENT_SERVICE_TEMPLATE
    systemctl daemon-reload
    systemctl enable "$NODEAGENT_SERVICE_NAME"
    systemctl restart "$NODEAGENT_SERVICE_NAME"

    sleep 2
    if systemctl is-active --quiet "$NODEAGENT_SERVICE_NAME"; then
        NODE_RUNNING_HERE="y"
    else
        warn "The exit-node service didn't stay up - check:" \
             "journalctl -u $NODEAGENT_SERVICE_NAME -n 50 --no-pager"
    fi
fi

PANEL_URL="$CONTROLPLANE_PUBLIC_URL/admin/"
log "Done"
cat <<SUMMARY

  Panel URL:     $PANEL_URL
  Admin token:   $ADMIN_TOKEN
  (save the admin token now - it is only stored, hashed, in Postgres and
  cannot be recovered from the server afterwards)

SUMMARY

if [ "$TLS_MODE" = "http" ]; then
    if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
        HTTP_PORT="3000"
    else
        HTTP_PORT="8080"
    fi
    warn "http mode: the admin token above (and every request to $PANEL_URL) travels in" \
         "plain text - anyone on the network path can read it. Make sure TCP $HTTP_PORT is open" \
         "in your VPS firewall/security group for this to be reachable at all."
fi

if [ -n "$NODE_TOKEN" ]; then
cat <<NODESUMMARY
  First node ID:     $NODE_ID
  First node token:  $NODE_TOKEN

NODESUMMARY
    if [ "$NODE_RUNNING_HERE" = "y" ]; then
        echo "  Exit node: running on this server as $NODEAGENT_SERVICE_NAME."
        echo "  Check on it any time with: systemctl status $NODEAGENT_SERVICE_NAME"
        echo
    else
cat <<NODESUMMARY
  On the exit-node machine:
    ./universal-bypass-tool --exit-node --managed \\
        --control-url "$CONTROLPLANE_PUBLIC_URL" \\
        --node-token "$NODE_TOKEN"

NODESUMMARY
    fi
fi

echo "Re-run this script any time to redeploy a newer --git-ref of openflux-server."

# Machine-readable line for automated callers (e.g. the app's SSH deployer) - see server/deployssh's resultLinePrefix.
echo "OPENFLUX_DEPLOY_RESULT panel_url=$PANEL_URL admin_token=$ADMIN_TOKEN node_token=${NODE_TOKEN:-}"
