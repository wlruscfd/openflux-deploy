#!/bin/bash
# OpenFlux control-plane auto-deployer.
#
# Run this directly ON the target VPS, as root (or via sudo):
#   curl -fsSL https://raw.githubusercontent.com/wlruscfd/openflux-deploy/main/install.sh -o install.sh
#   sudo bash install.sh
#
# It asks a handful of questions, then installs Postgres, Nginx, Go, builds
# and runs controlplane (see ../server/controlplane), registers and - by
# default - also runs a first exit node right here on this same server (see
# ../main.go and RUN_NODE_HERE below; say "n" if you're pointing it at a
# node running elsewhere instead), and puts the admin panel behind HTTPS.
# Debian/Ubuntu (apt-get) and AlmaLinux/RHEL-family (dnf) - it exits early
# with a clear message on anything else rather than doing the wrong thing
# silently.
set -euo pipefail

GO_VERSION="1.26.5"
INSTALL_ROOT="/opt/openflux"
BIN_DIR="$INSTALL_ROOT/bin"
SRC_DIR="$INSTALL_ROOT/server"
ENV_FILE="/etc/openflux/controlplane.env"
NODEAGENT_ENV_FILE="/etc/openflux/nodeagent.env"
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

# OS_FAMILY drives every package-manager-specific step below (package names,
# Postgres init, firewall, SELinux) - detected once here rather than
# re-checking `command -v` at each call site.
if command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY="debian"
elif command -v dnf >/dev/null 2>&1; then
    OS_FAMILY="rhel"
else
    die "This script only supports Debian/Ubuntu (apt-get) or AlmaLinux/RHEL-family (dnf) right now."
fi

# Reads VAR's value out of an already-written env file from a previous run,
# if any - lets a redeploy fall back to what's already there instead of
# generating a fresh value blind. Most critical for CONTROLPLANE_TOKEN_PEPPER
# below: every key/node/ingest-token secret is stored hashed with it, so a
# silently-regenerated pepper would make every one of them stop matching -
# not lost data exactly, but unusable, which is just as bad. Also how a
# redeploy recovers NODEAGENT_TOKEN (see $NODEAGENT_ENV_FILE below) - a node
# token is exactly as one-way-hashed as any other, so once the node already
# exists there is no fresh one to be had, only this saved copy.
read_existing_env() {
    local var="$1" file="${2:-$ENV_FILE}"
    [ -f "$file" ] || return 0
    grep "^$var=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- || true
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
    #
    # Reads from /dev/tty, not stdin: this script is meant to be run as
    # `curl ... | sudo bash`, where fd 0 is the pipe carrying the script's
    # own remaining bytes, not the keyboard - `read` on plain stdin there
    # would consume the script's own source as "input" instead of ever
    # reaching the terminal. /dev/tty is the actual controlling terminal
    # regardless of what's on fd 0, so this is what a real human at a
    # keyboard needs for prompts to work at all. Neither this script being
    # saved to a file first (the older documented flow) nor a truly
    # non-interactive caller (no controlling terminal at all, e.g. the
    # app's SSH exec) is affected: /dev/tty is always the right thing to
    # read in the first case, and simply fails to open in the second,
    # exactly like reading a closed stdin would - `|| true` treats both the
    # same and falls through to the default.
    local __var="$1" __prompt="$2" __default="${3:-}" __reply
    if [ -n "${!__var:-}" ]; then
        return
    fi
    if [ -n "$__default" ]; then
        read -r -p "$__prompt [$__default]: " __reply < /dev/tty 2>/dev/null || true
        __reply="${__reply:-$__default}"
    else
        read -r -p "$__prompt: " __reply < /dev/tty 2>/dev/null || true
    fi
    printf -v "$__var" '%s' "$__reply"
}

ask_secret() {
    local __var="$1" __prompt="$2" __reply
    if [ -n "${!__var:-}" ]; then
        return
    fi
    read -r -s -p "$__prompt (leave blank to auto-generate): " __reply < /dev/tty 2>/dev/null || true
    echo
    printf -v "$__var" '%s' "$__reply"
}

# ---------------------------------------------------------------------------
log "OpenFlux control-plane setup"
echo "Answer the questions below; press Enter to accept the default in [brackets]."

ask REPO_URL "openflux-server repo URL" "$DEFAULT_REPO_URL"
ask GIT_REF "Git branch/tag to deploy" "main"

echo
echo "Before you continue: your VPS/cloud firewall (security group) needs to allow"
echo "inbound TCP 443 (plus 80, briefly, for Let's Encrypt) for 'domain'/'ip' mode below -"
echo "443 is just the default and can be changed in a moment if it's already taken -"
echo "or TCP 8080 for 'http' mode - whichever you pick, that port has to be reachable"
echo "from the internet or nothing past this point will actually be usable."
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
# Referenced unconditionally below (nginx templates, CONTROLPLANE_PUBLIC_URL,
# the firewall step) regardless of mode - defaulted here so http mode (which
# never touches it) doesn't need special-casing at every use site.
HTTPS_PORT="${HTTPS_PORT:-443}"

ask WEB_PANEL "Install the SvelteKit web panel (Bun)? (y/n)" "y"

# AlmaLinux/RHEL-family ships firewalld active by default, allowing nothing
# but SSH in - unlike Debian/Ubuntu, which has no firewall active out of the
# box, so nothing was needed here for that family. Without this, the VPS/
# cloud firewall notice above would be satisfied but the host's own firewall
# would still silently drop everything.
if [ "$OS_FAMILY" = "rhel" ] && command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    log "Opening the needed port(s) in firewalld"
    if [ "$TLS_MODE" = "http" ]; then
        # The SvelteKit web panel is the single public origin in http mode
        # (it proxies /v1/* to controlplane itself), so it needs the public
        # port instead of controlplane.
        case "${WEB_PANEL:-n}" in
            y|Y) firewall-cmd --permanent --add-port=3000/tcp ;;
            *)   firewall-cmd --permanent --add-port=8080/tcp ;;
        esac
    else
        # --add-service=https is just a named alias for --add-port=443/tcp -
        # using --add-port directly here instead covers a non-default
        # HTTPS_PORT too.
        firewall-cmd --permanent --add-service=http --add-port="$HTTPS_PORT/tcp"
    fi
    firewall-cmd --reload
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
    ask RUN_NODE_HERE "Also run this exit node on this same server? (y/n)" "y"
fi

# ---------------------------------------------------------------------------
# http mode skips Nginx and certbot entirely - controlplane is reachable
# directly on plain HTTP with nothing in front of it, so there's no reverse
# proxy or certificate to install in the first place (see the
# CONTROLPLANE_LISTEN_ADDR/CONTROLPLANE_PUBLIC_URL write below, and the
# "Configuring Nginx"/"Requesting a TLS certificate" sections further down).
if [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    # postgresql-contrib provides the pgcrypto extension controlplane's own
    # first migration (0001_init.sql) requires - not pulled in by the
    # postgresql metapackage itself. This bit plain Debian/Astra despite
    # apparently working fine on stock Ubuntu, whose postgresql metapackage
    # depends on it transitively through a different chain of packages that
    # doesn't hold everywhere.
    if [ "$TLS_MODE" = "http" ]; then
        log "Installing packages (git, postgresql)"
        apt-get install -y git curl postgresql postgresql-contrib openssl unzip
    else
        log "Installing packages (git, postgresql, nginx, snapd)"
        apt-get install -y git curl postgresql postgresql-contrib nginx snapd openssl unzip
    fi
else
    # AlmaLinux/RHEL-family: postgresql-server (unlike Debian's postgresql
    # package, dnf's doesn't init or start itself - see the initdb/enable
    # step near "Setting up Postgres" below), postgresql-contrib (pgcrypto -
    # see the comment on the Debian branch above), and iptables-nft (the
    # exit-node setup below shells out to `iptables` directly; a minimal
    # AlmaLinux cloud image doesn't ship that binary at all by default,
    # favoring firewall-cmd/nft instead).
    if [ "$TLS_MODE" = "http" ]; then
        log "Installing packages (git, postgresql)"
        dnf install -y git curl postgresql-server postgresql postgresql-contrib openssl iptables-nft unzip
    else
        log "Installing packages (git, postgresql, nginx, snapd)"
        dnf install -y epel-release
        dnf install -y git curl postgresql-server postgresql postgresql-contrib nginx snapd openssl iptables-nft unzip
        # snapd needs its socket unit enabled and the classic-snap symlink
        # created by hand on RHEL-family - Debian's snapd package does both
        # itself as part of installation.
        systemctl enable --now snapd.socket
        ln -sf /var/lib/snapd/snap /snap
    fi
fi

if [ "$TLS_MODE" != "http" ]; then
    # ---------------------------------------------------------------------
    # Debian/Ubuntu's apt-packaged certbot (and AlmaLinux's EPEL one) is
    # years behind upstream (e.g. Ubuntu 24.04 ships 2.9.0) and doesn't know
    # about IP-address certificates at all (--ip-address landed in certbot
    # 5.3) - it rejects a bare IP outright ("will not issue certificates for
    # a bare IP address") before ever asking Let's Encrypt. certbot's own
    # snap is the officially recommended way to stay current, so that's what
    # obtain_tls below relies on. If snap isn't usable on this host, this is
    # deliberately non-fatal: obtain_tls will just fail to find certbot and
    # the existing self-signed fallback takes over.
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

# ---------------------------------------------------------------------------
log "Installing Go $GO_VERSION (apt's Go is usually too old for this project)"
if ! command -v /usr/local/go/bin/go >/dev/null 2>&1 || \
   ! /usr/local/go/bin/go version | grep -q "go$GO_VERSION"; then
    # dpkg doesn't exist on AlmaLinux/RHEL-family - fall back to uname -m's
    # naming there instead.
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

if [ "${RUN_NODE_HERE:-n}" = "y" ] || [ "${RUN_NODE_HERE:-n}" = "Y" ]; then
    log "Building the exit-node binary"
    ( cd "$SRC_DIR" && go build -o "$BIN_DIR/universal-bypass-tool" . )
fi

# The SvelteKit web panel (../server/controlplane/web) is optional: controlplane
# always serves its own embedded panel at /admin/ regardless (see admin.html),
# so if Bun isn't available or the panel fails to build, this only disables the
# fancier frontend, never the service. WEB_PANEL was asked before package
# install; a failed install/build flips it to "n" and the script carries on
# with the embedded panel - which is also exactly what happens for
# non-interactive callers (e.g. deployssh) that don't pre-set WEB_PANEL.
WEB_BUN="${WEB_BUN:-}"
if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
    log "Setting up Bun (for the SvelteKit web panel)"
    WEB_BUN="$(command -v bun || true)"
    if [ -z "$WEB_BUN" ]; then
        BUN_INSTALL_DIR="$INSTALL_ROOT/bun"
        if BUN_INSTALL="$BUN_INSTALL_DIR" curl -fsSL https://bun.sh/install | bash; then
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
    if ( cd "$SRC_DIR/controlplane/web" \
        && "$WEB_BUN" install \
        && "$WEB_BUN" run build \
        && mkdir -p "$WEB_DIR" \
        && cp -a build "$WEB_DIR/" \
        && cp server.js "$WEB_DIR/" ); then
        log "Web panel built to $WEB_DIR"
    else
        warn "Web panel build failed - falling back to controlplane's embedded panel."
        WEB_PANEL="n"
    fi
fi

# ---------------------------------------------------------------------------
log "Setting up the openflux system user"
id -u "$SYSTEM_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SYSTEM_USER"
chown -R "$SYSTEM_USER:$SYSTEM_USER" "$INSTALL_ROOT"

# ---------------------------------------------------------------------------
log "Setting up Postgres"
if [ "$OS_FAMILY" = "rhel" ]; then
    # Debian's postgresql package initializes and starts its own cluster on
    # install; dnf's postgresql-server does neither - both are needed by
    # hand, guarded so a redeploy's second run doesn't try to initdb an
    # already-initialized data directory. AlmaLinux's default module-stream
    # package uses /var/lib/pgsql/data directly (no version subdirectory);
    # the glob is a fallback for anything packaged the versioned way instead.
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
    # Default pg_hba.conf on RHEL-family authenticates 127.0.0.1/::1 TCP
    # connections with "ident", which rejects the password auth
    # $DATABASE_URL below relies on - Debian/Ubuntu's default already allows
    # it, so nothing analogous was needed there.
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

# ---------------------------------------------------------------------------
log "Writing $ENV_FILE"
mkdir -p "$(dirname "$ENV_FILE")"
# In ip/domain mode Nginx fronts both services on the same HTTPS origin, so
# controlplane stays on loopback and CONTROLPLANE_PUBLIC_URL names the
# Nginx host. http mode has no Nginx: if the web panel is installed it
# becomes the single public origin on :3000 and proxies /v1/* back to
# controlplane (which then only needs loopback); without it controlplane
# binds the public interface directly as before.
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

# The web panel's own env - CONTROLPLANE_UPSTREAM is where it forwards /v1/*
# and /healthz (in http mode this is what lets the browser use one origin);
# the web service still binds on loopback unless http mode needs it public.
if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
    cat > "$WEB_ENV_FILE" <<EOF
CONTROLPLANE_UPSTREAM=http://127.0.0.1:8080
CONTROLPLANE_WEB_HOST=$WEB_HOST
CONTROLPLANE_WEB_PORT=$WEB_PORT
EOF
    chown "$SYSTEM_USER:$SYSTEM_USER" "$WEB_ENV_FILE"
    chmod 600 "$WEB_ENV_FILE"
fi

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
systemctl enable "$SERVICE_NAME"
# Not "enable --now": on an already-running service (any redeploy),
# `start` is a no-op - the process would keep running the old binary with
# whatever env vars (admin token included) it started with, ignoring
# everything this run just rebuilt/rewrote. `restart` is what actually
# picks up a new binary or a changed $ENV_FILE either way, first install
# or redeploy alike.
systemctl restart "$SERVICE_NAME"

# The web panel service uses the same restart-not-just-start approach as
# controlplane above, so a redeploy picks up the freshly built frontend
# instead of keeping a stale one warm.
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

# ---------------------------------------------------------------------------
# http mode has no Nginx installed at all (see the package-install step
# above) - controlplane is reached directly on its own plain-HTTP port, so
# there's nothing to reverse-proxy and no certificate to request.
if [ "$TLS_MODE" != "http" ]; then

log "Configuring Nginx"
# SELinux ships enforcing by default on AlmaLinux/RHEL-family and blocks
# Nginx from making outbound connections at all (httpd_can_network_connect
# is off by default) - without this, every proxy_pass below to
# 127.0.0.1:8080 would 502 rather than reach controlplane. Debian/Ubuntu has
# no SELinux, so nothing analogous applies there.
if [ "$OS_FAMILY" = "rhel" ] && command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 2>/dev/null || true
fi
# Debian/Ubuntu's nginx package starts and enables its own service on
# install; Astra Linux's apparently doesn't ("nginx.service is not active,
# cannot reload" further down otherwise) - enable --now is a safe no-op if
# it's already running either way.
systemctl enable --now nginx
mkdir -p /var/www/certbot /etc/nginx/conf.d
# One snippet holds every proxy location block and is `include`d from both
# vhost templates below (they have to stay identical for the certbot --nginx
# and hand-written-https paths). With the SvelteKit panel installed, /admin/
# goes to Bun on :3000 while /v1/ + /healthz stay on controlplane - without
# it, everything lands on controlplane, which still serves its embedded
# panel at /admin/ on its own.
write_web_locations() {
    if [ "${WEB_PANEL:-n}" = "y" ] || [ "${WEB_PANEL:-n}" = "Y" ]; then
        cat > /etc/nginx/conf.d/openflux-locations.conf <<'WEB_LOCS'
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
        cat > /etc/nginx/conf.d/openflux-locations.conf <<'WEB_LOCS'
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
# conf.d/*.conf, not sites-available+sites-enabled: the latter is a
# Debian/Ubuntu packaging convention that not every Debian derivative
# actually ships (Astra Linux's nginx package doesn't create
# sites-available at all) and that AlmaLinux/RHEL-family's nginx package
# never uses in the first place - conf.d is the one layout every nginx
# package here actually includes from its default nginx.conf.
sed "s/__SERVER_NAME__/$SERVER_NAME/g" <<'NGINX_INITIAL_TEMPLATE' > "/etc/nginx/conf.d/openflux.conf"
# Written by install.sh. HTTP-only reverse proxy in front of the control
# plane services, also serving Let's Encrypt's HTTP-01 challenge from
# /var/www/certbot - obtain_tls below needs that reachable before it runs.
# Domain mode's certbot --nginx plugin rewrites this into an HTTPS block
# itself; IP mode (and the self-signed fallback) get a hand-written one -
# see obtain_tls and write_https_nginx_config.
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAME__;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    include /etc/nginx/conf.d/openflux-locations.conf;
}
NGINX_INITIAL_TEMPLATE
# Both are stock default vhosts that would otherwise fight ours over
# listening on :80 as the default_server - Debian/Ubuntu/Astra's under
# sites-enabled, AlmaLinux/RHEL-family's directly in conf.d. Harmless if
# whichever one doesn't apply to this OS isn't present.
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf
# A server first deployed before this script moved to conf.d wrote its own
# vhost under sites-available+sites-enabled instead - a redeploy that just
# adds the new conf.d/openflux.conf alongside it would leave both loaded at
# once, fighting over the same :80/:443, without nginx -t necessarily
# refusing to start (it just warns and picks one, likely by parse order).
# Remove our own old-layout vhost specifically (not the whole directory -
# never touch anything this script didn't create itself).
rm -f /etc/nginx/sites-enabled/openflux /etc/nginx/sites-available/openflux
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
    local redirect_port_suffix=""
    [ "$HTTPS_PORT" = "443" ] || redirect_port_suffix=":$HTTPS_PORT"
    sed -e "s/__SERVER_NAME__/$SERVER_NAME/g" \
        -e "s#__CERT_PATH__#$cert#g" \
        -e "s#__KEY_PATH__#$key#g" \
        -e "s/__HTTPS_PORT__/$HTTPS_PORT/g" \
        -e "s/__REDIRECT_PORT_SUFFIX__/$redirect_port_suffix/g" <<'NGINX_HTTPS_TEMPLATE' > /etc/nginx/conf.d/openflux.conf
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

    include /etc/nginx/conf.d/openflux-locations.conf;
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
        # --https-port only matters when it differs from certbot's own
        # default (443) - passed unconditionally is harmless either way,
        # but this keeps the common-case invocation exactly as before.
        local https_port_flag=""
        [ "$HTTPS_PORT" = "443" ] || https_port_flag="--https-port $HTTPS_PORT"
        certbot --nginx --non-interactive --agree-tos -m "$LE_EMAIL" -d "$SERVER_NAME" --redirect $https_port_flag
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

else
    log "http mode: skipping Nginx/TLS - controlplane is reachable directly on $CONTROLPLANE_PUBLIC_URL"
fi

# ---------------------------------------------------------------------------
# A caller can hand NODE_TOKEN in directly (matching every other
# ask()-skippable variable in this script) to recover a node whose token
# neither the API nor $NODEAGENT_ENV_FILE can produce anymore - see the
# warn() below.
NODE_TOKEN="${NODE_TOKEN:-}"
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
        # A redeploy can't get a fresh token for a node that already exists
        # (one-way hashed, same as any other) - the only way this run's
        # locally-run node keeps working is reusing what a previous run
        # already saved, or one the caller hands in directly (matching every
        # other ask()-skippable variable in this script). If neither is
        # available (e.g. the node was created by hand, or RUN_NODE_HERE was
        # "n" before), there is genuinely nothing to recover here short of
        # rotating.
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

# ---------------------------------------------------------------------------
NODE_RUNNING_HERE="n"
if { [ "${RUN_NODE_HERE:-n}" = "y" ] || [ "${RUN_NODE_HERE:-n}" = "Y" ]; } && [ -n "$NODE_TOKEN" ]; then
    log "Setting up the exit node on this server"

    # The exit node relays real TCP/IP packets through a raw socket instead
    # of the kernel's own TCP stack, so the kernel - which knows nothing
    # about these connections - would otherwise see their unexpected
    # inbound packets and RST them itself. -C first so a redeploy doesn't
    # pile up a duplicate copy of this rule every time.
    iptables -C OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null || \
        iptables -A OUTPUT -p tcp --tcp-flags RST RST -j DROP

    # Same problem, UDP side: the raw socket claims inbound UDP datagrams
    # for ports the kernel's own UDP stack never opened a socket on, so the
    # kernel answers those with its own "port unreachable" ICMP before our
    # relayed response ever gets a chance to - tearing the flow down from
    # the remote peer's point of view mid-exchange.
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
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
NODEAGENT_SERVICE_TEMPLATE
    systemctl daemon-reload
    systemctl enable "$NODEAGENT_SERVICE_NAME"
    # restart, not enable --now - see the identical comment on the
    # controlplane service above; the exact same stale-process trap applies
    # here on every redeploy.
    systemctl restart "$NODEAGENT_SERVICE_NAME"

    sleep 2
    if systemctl is-active --quiet "$NODEAGENT_SERVICE_NAME"; then
        NODE_RUNNING_HERE="y"
    else
        warn "The exit-node service didn't stay up - check:" \
             "journalctl -u $NODEAGENT_SERVICE_NAME -n 50 --no-pager"
    fi
fi

# ---------------------------------------------------------------------------
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

# One machine-readable line for automated callers (e.g. the app's SSH
# deployer) to parse - see server/deployssh's resultLinePrefix. Harmless
# to ignore if you're reading this as a human; everything in it is already
# in the summary above.
echo "OPENFLUX_DEPLOY_RESULT panel_url=$PANEL_URL admin_token=$ADMIN_TOKEN node_token=${NODE_TOKEN:-}"
