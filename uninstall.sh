#!/bin/bash
# OpenFlux uninstaller - run as root on the VPS: curl -fsSL .../uninstall.sh | sudo bash
set -uo pipefail

INSTALL_ROOT="/opt/openflux"
CONFIG_DIR="/etc/openflux"
ENV_FILE="$CONFIG_DIR/controlplane.env"
SERVICES=(openflux-web openflux-nodeagent openflux-controlplane)
NGINX_CONF="/etc/nginx/conf.d/openflux.conf"
SYSTEM_USER="openflux"
DB_NAME="openflux"
DB_USER="openflux"

OPENFLUX_LANG="${OPENFLUX_LANG:-ru}"
CONFIRM="${CONFIRM:-}"
NO_BACKUP="${NO_BACKUP:-n}"
REMOVE_GO="${REMOVE_GO:-n}"

say() {
    if [ "$OPENFLUX_LANG" = "en" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "$(say 'Запустите от root (sudo bash uninstall.sh).' 'Run this as root (sudo bash uninstall.sh).')"

found=0
for path in "$INSTALL_ROOT" "$CONFIG_DIR" "$NGINX_CONF"; do
    [ -e "$path" ] && found=1
done
for svc in "${SERVICES[@]}"; do
    [ -f "/etc/systemd/system/$svc.service" ] && found=1
done
if [ "$found" -eq 0 ]; then
    say "OpenFlux на этом сервере не найден - удалять нечего." "OpenFlux was not found on this server - nothing to remove."
    exit 0
fi

PUBLIC_URL=""
if [ -f "$ENV_FILE" ]; then
    PUBLIC_URL="$(grep '^CONTROLPLANE_PUBLIC_URL=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
fi
CERT_NAME="$(printf '%s' "$PUBLIC_URL" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"

echo
say "Будет удалено ВСЁ, что поставил install.sh:" "Everything install.sh set up will be removed:"
say "  - сервисы ${SERVICES[*]} и их systemd-юниты" "  - the ${SERVICES[*]} services and their systemd units"
say "  - каталоги $INSTALL_ROOT и $CONFIG_DIR (бинарники, исходники, веб-панель, токены, TLS-ключи)" "  - $INSTALL_ROOT and $CONFIG_DIR (binaries, sources, web panel, tokens, TLS keys)"
say "  - база Postgres '$DB_NAME' и роль '$DB_USER' (ключи, ноды, статистика)" "  - the Postgres database '$DB_NAME' and role '$DB_USER' (keys, nodes, statistics)"
say "  - конфиг Nginx $NGINX_CONF и сертификат Let's Encrypt для '${CERT_NAME:-?}'" "  - the Nginx config $NGINX_CONF and the Let's Encrypt certificate for '${CERT_NAME:-?}'"
say "  - системный пользователь '$SYSTEM_USER' и правила iptables ноды" "  - the '$SYSTEM_USER' system user and the node's iptables rules"
say "Postgres, Nginx, snapd, git и прочие пакеты НЕ удаляются - они могут быть нужны другим сервисам." "Postgres, Nginx, snapd, git and other packages are NOT removed - other services may need them."
if [ "$NO_BACKUP" != "y" ]; then
    say "Перед удалением будет сделан дамп базы в /root/openflux-uninstall-<дата>/." "A database dump is saved to /root/openflux-uninstall-<timestamp>/ before anything is deleted."
else
    warn "$(say 'NO_BACKUP=y: дамп базы НЕ делается, данные пропадут безвозвратно.' 'NO_BACKUP=y: no database dump will be made, the data will be gone for good.')"
fi
echo

if [ "$CONFIRM" != "yes" ]; then
    if exec 3<>/dev/tty 2>/dev/null; then
        exec 3<&- 3>&-
        printf '%s' "$(say 'Для подтверждения введите DELETE: ' 'Type DELETE to confirm: ')" > /dev/tty
        read -r reply < /dev/tty || reply=""
        [ "$reply" = "DELETE" ] || die "$(say 'Отменено, ничего не удалено.' 'Cancelled, nothing was removed.')"
    else
        die "$(say 'Нет терминала для подтверждения. Запустите с CONFIRM=yes, если уверены.' 'No terminal to confirm on. Re-run with CONFIRM=yes if you are sure.')"
    fi
fi

BACKUP_DIR=""
if [ "$NO_BACKUP" != "y" ]; then
    BACKUP_DIR="/root/openflux-uninstall-$(date +%Y%m%d-%H%M%S)"
    step "$(say "Сохраняю дамп базы и env-файл в $BACKUP_DIR" "Saving a database dump and env file to $BACKUP_DIR")"
    mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    if command -v pg_dump >/dev/null 2>&1 &&
        sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
        if ! sudo -u postgres pg_dump "$DB_NAME" > "$BACKUP_DIR/openflux.sql"; then
            die "$(say 'Не удалось сделать дамп базы - ничего не удалено. Повторите с NO_BACKUP=y, если дамп не нужен.' 'The database dump failed - nothing was removed. Re-run with NO_BACKUP=y if you do not need one.')"
        fi
    else
        warn "$(say 'База не найдена - дампить нечего.' 'No database found - nothing to dump.')"
    fi
    cp "$ENV_FILE" "$BACKUP_DIR/controlplane.env" 2>/dev/null || true
    [ -f "$CONFIG_DIR/nodeagent.env" ] && cp "$CONFIG_DIR/nodeagent.env" "$BACKUP_DIR/nodeagent.env"
    chmod -R go-rwx "$BACKUP_DIR"
fi

step "$(say 'Останавливаю и удаляю сервисы' 'Stopping and removing services')"
for svc in "${SERVICES[@]}"; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
    rm -rf "/etc/systemd/system/$svc.service" "/etc/systemd/system/$svc.service.d"
done
systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

step "$(say 'Убираю правила iptables ноды' "Removing the node's iptables rules")"
if command -v iptables >/dev/null 2>&1; then
    while iptables -D OUTPUT -p tcp --tcp-flags RST RST -m mark ! --mark 0x2547 -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --tcp-flags RST RST -j DROP 2>/dev/null; do :; done
    while iptables -D OUTPUT -p icmp --icmp-type port-unreachable -j DROP 2>/dev/null; do :; done
fi

step "$(say 'Убираю конфиг Nginx и сертификат' 'Removing the Nginx config and certificate')"
rm -f "$NGINX_CONF" /etc/nginx/sites-enabled/openflux /etc/nginx/sites-available/openflux /etc/nginx/conf.d/openflux-locations.conf
if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx || warn "$(say 'Nginx не перезагрузился - проверьте: nginx -t' 'Nginx did not reload - check: nginx -t')"
    else
        warn "$(say 'После удаления конфига nginx -t не проходит - проверьте остальные конфиги вручную.' 'nginx -t fails after removing the config - check your other configs by hand.')"
    fi
fi
if [ -n "$CERT_NAME" ] && command -v certbot >/dev/null 2>&1 && [ -d "/etc/letsencrypt/live/$CERT_NAME" ]; then
    certbot delete --non-interactive --cert-name "$CERT_NAME" >/dev/null 2>&1 ||
        warn "$(say "Не удалось удалить сертификат $CERT_NAME - удалите вручную: certbot delete --cert-name $CERT_NAME" "Could not delete the certificate $CERT_NAME - remove it by hand: certbot delete --cert-name $CERT_NAME")"
fi
rmdir /var/www/certbot 2>/dev/null || true

step "$(say 'Удаляю базу и роль Postgres' 'Dropping the Postgres database and role')"
if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);" >/dev/null 2>&1 ||
        { sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_NAME';" >/dev/null 2>&1;
          sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" ||
              warn "$(say 'Не удалось удалить базу.' 'Could not drop the database.')"; }
    sudo -u postgres psql -c "DROP ROLE IF EXISTS $DB_USER;" ||
        warn "$(say 'Не удалось удалить роль.' 'Could not drop the role.')"
else
    warn "$(say 'Postgres не запущен - базу и роль удалите вручную, если они остались.' 'Postgres is not running - drop the database and role by hand if they remain.')"
fi

step "$(say 'Удаляю файлы и пользователя' 'Removing files and the system user')"
rm -rf "$INSTALL_ROOT" "$CONFIG_DIR" /tmp/openflux-install.sh
id -u "$SYSTEM_USER" >/dev/null 2>&1 && userdel "$SYSTEM_USER" 2>/dev/null
git config --global --unset-all safe.directory "$INSTALL_ROOT/server" >/dev/null 2>&1 || true
if [ "$REMOVE_GO" = "y" ]; then
    rm -rf /usr/local/go
fi

echo
say "Готово: OpenFlux удалён с этого сервера." "Done: OpenFlux has been removed from this server."
[ -n "$BACKUP_DIR" ] && say "Дамп базы и env-файлы: $BACKUP_DIR (удалите вручную, когда не понадобятся)." "Database dump and env files: $BACKUP_DIR (delete them by hand once you no longer need them)."
say "Если в firewall/security group вы открывали порты 80/443 под панель - закройте их вручную." "If you opened ports 80/443 in a firewall/security group for the panel, close them by hand."
[ "$REMOVE_GO" = "y" ] || say "Go в /usr/local/go оставлен (удалить: REMOVE_GO=y)." "Go in /usr/local/go was left in place (remove it with REMOVE_GO=y)."
