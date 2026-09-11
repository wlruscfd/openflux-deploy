# OpenFlux deployer

**English** | [Русский](README.ru.md)

A fork of [p1neappleXpress/OpenFlux](https://github.com/p1neappleXpress/OpenFlux). This repo holds
`install.sh`: a script that asks a handful of questions and rolls out
[openflux-server](https://github.com/wlruscfd/openflux-server)'s `controlplane` — Postgres, the
systemd service, Nginx, and an HTTPS certificate (Let's Encrypt) with auto-renewal — on a fresh
Debian/Ubuntu VPS.

## Usage

Run it **directly on the target VPS**, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/wlruscfd/openflux-deploy/main/install.sh -o install.sh
sudo bash install.sh
```

(Not orchestrated remotely over SSH from your own machine - simpler and more robust to just run it
where it's actually provisioning things.)

It will ask for:
- Which `openflux-server` repo/branch to deploy (defaults to the `wlruscfd` one, override for your
  own fork).
- **TLS mode**: `domain` (standard Let's Encrypt via certbot's Nginx plugin - you'll need a domain
  already pointed at this server's IP, plus an email for the Let's Encrypt account) or `ip` (no
  domain needed; attempts Let's Encrypt's short-lived IP-address certificate, falling back to a
  self-signed certificate - with a clear warning - if that doesn't succeed, so the panel is still
  reachable over HTTPS either way).
- An admin token (or press Enter to generate one) - this is what you'll paste into the admin panel
  at `https://<your-domain-or-ip>/admin/` afterwards.
- Whether to register a first exit node right away.

At the end it prints the panel URL, the admin token (**save it - it's stored hashed and can't be
recovered from the server afterwards**), and, if you registered one, the first exit node's token
and the exact flags to hand to whoever runs that exit node:

```bash
./universal-bypass-tool --exit-node --managed \
    --control-url "https://<your-domain-or-ip>" \
    --node-token "<node token>"
```

Re-running the script later redeploys a newer branch/tag of `openflux-server` in place.

## Non-interactive / automated use

Every prompt is skipped if its variable is already set in the environment (`REPO_URL`, `GIT_REF`,
`TLS_MODE`, `DOMAIN`, `LE_EMAIL`, `SERVER_IP`, `ADMIN_TOKEN`, `DB_PASSWORD`, `REGISTER_NODE`,
`NODE_NAME`, `NODE_MAX_KEYS` - the exact names used inside the script), so it can be driven without
a human at the keyboard:

```bash
REPO_URL=https://github.com/wlruscfd/openflux-server.git GIT_REF=main \
TLS_MODE=domain DOMAIN=panel.example.com LE_EMAIL=you@example.com \
ADMIN_TOKEN="$(openssl rand -hex 32)" DB_PASSWORD="$(openssl rand -hex 24)" \
REGISTER_NODE=y NODE_NAME=node-1 NODE_MAX_KEYS=500 \
bash install.sh
```

This is exactly what the [openflux-app](https://github.com/wlruscfd/openflux-app) Android app's
**Deploy** tab does over SSH, so you never see a prompt when deploying from the app.

## What it sets up

- `openflux` system user, `/opt/openflux/{bin,server}`, `/etc/openflux/controlplane.env` (mode
  `600`, holds the DB URL / token pepper / admin token).
- A local Postgres role + database.
- `openflux-controlplane.service` (systemd unit, embedded in install.sh), enabled and started.
- Nginx reverse-proxying to `127.0.0.1:8080`, with TLS per the mode above.

## Honesty about the IP-certificate path

Let's Encrypt's short-lived certificates for bare IP addresses are newer and less battle-tested
than the domain path, and need a recent certbot (`--ip-address` needs 5.3+, webroot support for it
needs 5.4+) - Debian/Ubuntu's own apt package is normally far older than that and doesn't support
IP certificates at all, so this script installs certbot via snap specifically to get a current
enough one. That said, this is still a newer Let's Encrypt capability with its own moving parts;
if issuance still fails for you, the script notices and falls back to a self-signed certificate
rather than leaving the install half-finished. If you can get a domain pointed at the server
instead, that path is the well-trodden one.
