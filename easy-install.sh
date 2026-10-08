#!/bin/bash
# OpenFlux "no questions asked" installer - run as root on a fresh VPS: curl -fsSL .../easy-install.sh | sudo bash
set -uo pipefail

RAW_BASE="https://raw.githubusercontent.com/wlruscfd/openflux-deploy/main"
LOG_FILE="/var/log/openflux-install.log"
SWAP_FILE="/swapfile-openflux"
MIN_MEMORY_MB=1800
MIN_DISK_MB=2500

OPENFLUX_LANG="${OPENFLUX_LANG:-ru}"

say() {
    if [ "$OPENFLUX_LANG" = "en" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

port_in_use() { ss -tln 2>/dev/null | grep -qE "[:.]$1[[:space:]]"; }

detect_public_ip() {
    local ip svc
    for svc in https://ifconfig.me https://icanhazip.com https://api.ipify.org https://ipinfo.io/ip; do
        ip="$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')" || true
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$ip" =~ ^[0-9a-fA-F:]+:[0-9a-fA-F:]+$ ]]; then
            printf '%s' "$ip"
            return
        fi
    done
    ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true
}

[ "$(id -u)" -eq 0 ] || die "$(say 'Запустите от root: ... | sudo bash' 'Run this as root: ... | sudo bash')"
command -v curl >/dev/null 2>&1 || die "$(say 'Нужен curl (apt-get install -y curl).' 'curl is required (apt-get install -y curl).')"
if ! command -v apt-get >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1; then
    die "$(say 'Поддерживаются только Debian/Ubuntu и AlmaLinux/RHEL.' 'Only Debian/Ubuntu and AlmaLinux/RHEL-family systems are supported.')"
fi

step "$(say 'Проверяю сервер' 'Checking the server')"
free_disk_mb="$(df -Pm /opt 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "${free_disk_mb:-}" ] && [ "$free_disk_mb" -lt "$MIN_DISK_MB" ]; then
    die "$(say "Мало места на диске: свободно ${free_disk_mb} МБ, нужно хотя бы ${MIN_DISK_MB} МБ." "Not enough disk space: ${free_disk_mb} MB free, at least ${MIN_DISK_MB} MB needed.")"
fi

total_memory_mb="$(awk '/^MemTotal:/ {m=$2} /^SwapTotal:/ {s=$2} END {print int((m+s)/1024)}' /proc/meminfo)"
if [ "$total_memory_mb" -lt "$MIN_MEMORY_MB" ]; then
    warn "$(say "Памяти (с учётом swap) всего ${total_memory_mb} МБ - сборка на Go на таком сервере может молча упасть по OOM. Создаю swap 2 ГБ." "Only ${total_memory_mb} MB of memory (including swap) - the Go build can be silently OOM-killed on a server this small. Creating a 2 GB swap file.")"
    if [ -e "$SWAP_FILE" ] && swapon "$SWAP_FILE" 2>/dev/null ||
        { [ ! -e "$SWAP_FILE" ] &&
        { fallocate -l 2G "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=none; } &&
        chmod 600 "$SWAP_FILE" && mkswap "$SWAP_FILE" >/dev/null && swapon "$SWAP_FILE"; }; then
        grep -q "^$SWAP_FILE " /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
    else
        warn "$(say 'Не удалось создать swap (контейнерный VPS?) - продолжаю без него.' 'Could not create swap (a containerized VPS?) - continuing without it.')"
    fi
fi

: "${TLS_MODE:=ip}"
: "${REPO_URL:=https://github.com/wlruscfd/openflux-server.git}"
: "${GIT_REF:=main}"
: "${WEB_PANEL:=y}"
: "${REGISTER_NODE:=y}"
: "${NODE_NAME:=node-1}"
: "${NODE_MAX_KEYS:=999999}"
: "${RUN_NODE_HERE:=y}"

if [ -z "${HTTPS_PORT:-}" ]; then
    HTTPS_PORT=443
    for candidate in 443 8443 9443 10443; do
        if ! port_in_use "$candidate"; then HTTPS_PORT="$candidate"; break; fi
    done
fi
if [ -z "${RESERVE_PORT_80:-}" ]; then
    if port_in_use 80 && ! pgrep -x nginx >/dev/null 2>&1; then RESERVE_PORT_80=y; else RESERVE_PORT_80=n; fi
fi

if [ "$TLS_MODE" = "domain" ]; then
    [ -n "${DOMAIN:-}" ] || die "$(say 'Для TLS_MODE=domain укажите DOMAIN=ваш.домен и LE_EMAIL=вы@почта.' 'TLS_MODE=domain needs DOMAIN=your.domain and LE_EMAIL=you@mail.')"
    [ -n "${LE_EMAIL:-}" ] || die "$(say 'Для TLS_MODE=domain укажите LE_EMAIL=вы@почта.' 'TLS_MODE=domain needs LE_EMAIL=you@mail.')"
else
    SERVER_IP="${SERVER_IP:-$(detect_public_ip)}"
    [ -n "$SERVER_IP" ] || die "$(say 'Не удалось определить публичный IP. Запустите с SERVER_IP=1.2.3.4.' 'Could not detect the public IP. Re-run with SERVER_IP=1.2.3.4.')"
fi

ADMIN_TOKEN="${ADMIN_TOKEN:-$(random_hex 32)}"
DB_PASSWORD="${DB_PASSWORD:-$(random_hex 24)}"

step "$(say 'Скачиваю установщик' 'Downloading the installer')"
installer="$(mktemp /tmp/openflux-install.XXXXXX)"
trap 'rm -f "$installer"' EXIT
curl -fsSL "$RAW_BASE/install.sh?_=$(date +%s)" -o "$installer" ||
    die "$(say 'Не удалось скачать install.sh с GitHub (сеть блокирует raw.githubusercontent.com?).' 'Could not download install.sh from GitHub (is raw.githubusercontent.com blocked?).')"
head -n1 "$installer" | grep -q '^#!/bin/bash' ||
    die "$(say 'Скачанный файл не похож на install.sh - повторите попытку позже.' 'The downloaded file does not look like install.sh - try again later.')"

say "Устанавливаю OpenFlux. Это займёт 5-15 минут, подробный лог: $LOG_FILE" "Installing OpenFlux. This takes 5-15 minutes, full log: $LOG_FILE"
install -m 600 /dev/null "$LOG_FILE"

export OPENFLUX_NONINTERACTIVE=1
export TLS_MODE REPO_URL GIT_REF WEB_PANEL REGISTER_NODE NODE_NAME NODE_MAX_KEYS RUN_NODE_HERE
export HTTPS_PORT RESERVE_PORT_80 ADMIN_TOKEN DB_PASSWORD
[ -n "${SERVER_IP:-}" ] && export SERVER_IP
[ -n "${DOMAIN:-}" ] && export DOMAIN
[ -n "${LE_EMAIL:-}" ] && export LE_EMAIL

bash "$installer" </dev/null 2>&1 | tee -a "$LOG_FILE"
install_status="${PIPESTATUS[0]}"

if [ "$install_status" -ne 0 ]; then
    echo
    warn "$(say "Установка прервалась (код $install_status). Последние строки лога:" "The installation stopped (exit code $install_status). Last log lines:")"
    tail -n 25 "$LOG_FILE" >&2
    warn "$(say "Полный лог: $LOG_FILE. Установку можно безопасно запустить заново - данные не потеряются." "Full log: $LOG_FILE. It is safe to run the installation again - no data is lost.")"
    exit "$install_status"
fi

result_line="$(grep '^OPENFLUX_DEPLOY_RESULT ' "$LOG_FILE" | tail -n1)"
field() { printf '%s' "$result_line" | tr ' ' '\n' | grep "^$1=" | head -n1 | cut -d= -f2-; }
panel_url="$(field panel_url)"
admin_token="$(field admin_token)"
node_token="$(field node_token)"

listen_addr="$(grep '^CONTROLPLANE_LISTEN_ADDR=' /etc/openflux/controlplane.env 2>/dev/null | tail -n1 | cut -d= -f2-)"
problems=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        printf '  [OK] %s\n' "$1"
    else
        printf '  [!!] %s\n' "$1"
        problems=$((problems + 1))
    fi
}

step "$(say 'Проверяю, что всё реально работает' 'Verifying that everything actually works')"
check "$(say 'controlplane запущен и отвечает' 'controlplane is running and answers')" \
    "curl -fsS --max-time 5 http://${listen_addr:-127.0.0.1:8080}/healthz"
if [ "$TLS_MODE" != "http" ]; then
    check "$(say 'Nginx запущен' 'Nginx is running')" "systemctl is-active --quiet nginx"
fi
if [ "$REGISTER_NODE" = "y" ]; then
    check "$(say 'Нода зарегистрирована' 'The node is registered')" "[ -n '$node_token' ]"
    if [ "$RUN_NODE_HERE" = "y" ]; then
        check "$(say 'exit-нода работает на этом сервере' 'The exit node is running on this server')" "systemctl is-active --quiet openflux-nodeagent"
    fi
fi

echo
echo "================================================================"
if [ "$problems" -eq 0 ]; then
    say "  OpenFlux установлен и работает" "  OpenFlux is installed and running"
else
    say "  OpenFlux установлен, но есть проблемы ($problems) - см. [!!] выше" "  OpenFlux is installed, but with $problems problem(s) - see [!!] above"
fi
echo "================================================================"
panel_shown="${panel_url:-${SERVER_IP:-${DOMAIN:-}}}"
say "  Панель управления:  $panel_shown" "  Admin panel:  $panel_shown"
say "  Токен админа:       ${admin_token:-$ADMIN_TOKEN}" "  Admin token:  ${admin_token:-$ADMIN_TOKEN}"
say "  (СОХРАНИТЕ токен сейчас - на сервере он хранится только в виде хеша)" "  (SAVE the token now - the server only keeps a hash of it)"
echo
say "Что дальше:" "What next:"
say "  1. Откройте в вашем firewall/security group хостинга порты 80 и $HTTPS_PORT (TCP) - без этого панель не откроется." "  1. Open ports 80 and $HTTPS_PORT (TCP) in your hosting provider's firewall/security group - the panel will not open otherwise."
say "  2. Откройте адрес панели в браузере. Если браузер ругается на сертификат - это нормально для режима по IP, нажмите «Дополнительно» -> «Всё равно перейти»." "  2. Open the panel address in a browser. A certificate warning is normal in IP mode - choose \"Advanced\" -> \"Proceed anyway\"."
say "  3. Вставьте токен админа, создайте ключ и импортируйте его в приложение OpenFlux (QR-код или ссылка)." "  3. Paste the admin token, create a key and import it into the OpenFlux app (QR code or link)."
echo
say "Лог установки: $LOG_FILE" "Installation log: $LOG_FILE"
if [ "$RUN_NODE_HERE" = "y" ]; then
    say "Что делает exit-нода (капча, куки, подключение к документу): journalctl -u openflux-nodeagent -f" "What the exit node is doing (captcha, cookies, provider connection): journalctl -u openflux-nodeagent -f"
fi
say "Удалить всё:    curl -fsSL $RAW_BASE/uninstall.sh | sudo bash" "Remove everything:    curl -fsSL $RAW_BASE/uninstall.sh | sudo bash"
if [ "$REGISTER_NODE" = "y" ] && [ -z "$node_token" ]; then
    echo
    warn "$(say 'ВНИМАНИЕ: нода не зарегистрировалась. Создайте её вручную в панели или запустите установку заново.' 'WARNING: the node was not registered. Create it by hand in the panel or run the installation again.')"
fi
[ "$problems" -eq 0 ]
