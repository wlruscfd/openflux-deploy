# Раскатчик OpenFlux

[English](README.md) | **Русский**

Форк [p1neappleXpress/OpenFlux](https://github.com/p1neappleXpress/OpenFlux). В этом репозитории
лежит `install.sh` — скрипт, который задаёт несколько вопросов и разворачивает `controlplane` из
[openflux-server](https://github.com/wlruscfd/openflux-server): Postgres, systemd-сервис, Nginx и
HTTPS-сертификат (Let's Encrypt) с автопродлением — на чистом Debian/Ubuntu VPS.

## Использование

Запустите его **прямо на целевом VPS**, от root:

```bash
curl -fsSL https://raw.githubusercontent.com/wlruscfd/openflux-deploy/main/install.sh -o install.sh
sudo bash install.sh
```

(Скрипт не оркеструет установку удалённо по SSH с вашей машины — проще и надёжнее просто запустить
его там, где он реально что-то разворачивает.)

Он спросит:
- Какой репозиторий/ветку `openflux-server` разворачивать (по умолчанию — репозиторий `wlruscfd`,
  можно указать свой форк).
- **Режим TLS**: `domain` (обычный Let's Encrypt через nginx-плагин certbot — нужен домен, уже
  указывающий на IP этого сервера, и email для регистрации в Let's Encrypt) или `ip` (без домена;
  пытается получить короткоживущий сертификат Let's Encrypt для IP-адреса, а если не получится —
  откатывается на самоподписанный сертификат с явным предупреждением, чтобы панель в любом случае
  была доступна по HTTPS).
- Токен администратора (или нажмите Enter, чтобы сгенерировать) — именно его вы вставите потом в
  панель управления по адресу `https://<ваш-домен-или-ip>/admin/`.
- Регистрировать ли первую exit-ноду сразу.

В конце скрипт выведет URL панели, токен администратора (**сохраните его — он хранится на сервере
только в виде хеша и не восстанавливается**) и, если нода была зарегистрирована, её токен и точные
флаги для запуска этой exit-ноды:

```bash
./universal-bypass-tool --exit-node --managed \
    --control-url "https://<ваш-домен-или-ip>" \
    --node-token "<токен ноды>"
```

Повторный запуск скрипта позже разворачивает более новую ветку/тег `openflux-server` поверх
текущей установки.

## Неинтерактивный / автоматический запуск

Любой вопрос пропускается, если соответствующая переменная уже задана в окружении (`REPO_URL`,
`GIT_REF`, `TLS_MODE`, `DOMAIN`, `LE_EMAIL`, `SERVER_IP`, `ADMIN_TOKEN`, `DB_PASSWORD`,
`REGISTER_NODE`, `NODE_NAME`, `NODE_MAX_KEYS` — именно эти имена используются внутри скрипта),
поэтому его можно запускать без человека за клавиатурой:

```bash
REPO_URL=https://github.com/wlruscfd/openflux-server.git GIT_REF=main \
TLS_MODE=domain DOMAIN=panel.example.com LE_EMAIL=you@example.com \
ADMIN_TOKEN="$(openssl rand -hex 32)" DB_PASSWORD="$(openssl rand -hex 24)" \
REGISTER_NODE=y NODE_NAME=node-1 NODE_MAX_KEYS=500 \
bash install.sh
```

Именно так вкладка **Деплой** Android-приложения
[openflux-app](https://github.com/wlruscfd/openflux-app) запускает этот скрипт по SSH — вопросов
при этом не возникает вообще.

## Что настраивается

- Системный пользователь `openflux`, `/opt/openflux/{bin,server}`, `/etc/openflux/controlplane.env`
  (права `600`, хранит DB URL / token pepper / admin token).
- Локальная роль + база данных Postgres.
- `openflux-controlplane.service` (systemd-юнит, встроен в install.sh), включён и запущен.
- Nginx с обратным прокси на `127.0.0.1:8080` и TLS согласно выбранному режиму.

## Честно про режим сертификата для IP

Короткоживущие сертификаты Let's Encrypt для голых IP-адресов — более новая и менее обкатанная
возможность, чем путь с доменом, и требует свежего certbot (`--ip-address` появился в 5.3, поддержка
через webroot — в 5.4). Штатный пакет certbot из apt в Debian/Ubuntu обычно намного старше и вообще
не умеет в сертификаты для IP, поэтому скрипт ставит certbot через snap — специально ради
достаточно свежей версии. Тем не менее это всё ещё новая возможность Let's Encrypt со своими
нюансами; если выпуск сертификата всё же не удастся, скрипт заметит ошибку и откатится на
самоподписанный сертификат, а не оставит установку в полусломанном состоянии. Если есть
возможность направить домен на сервер — этот путь гораздо более проверенный.
