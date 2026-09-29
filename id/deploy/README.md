# cubechat-id deployment

Runs beside `cubechat-push` on the droplet (Node 22, user `cubechat`), at
`https://id.cubechat.tech` through the shared Caddy. Design:
`docs/superpowers/specs/2026-09-29-cube-id-names-design.md`.

## Install or update

```bash
rsync -a --delete --exclude node_modules --exclude '*.db*' --exclude .env id/ root@209.38.225.225:/opt/cubechat-id/
ssh root@209.38.225.225 'cd /opt/cubechat-id && npm install --omit=dev && chown -R cubechat:cubechat /opt/cubechat-id'
```

`/opt/cubechat-id/.env` (mode 600, owner cubechat), created once:

```
PORT=8090
DB_PATH=/opt/cubechat-id/names.db
BANNED_PATH=/opt/cubechat-push/banned.json
ADMIN_TOKEN=<openssl rand -hex 32>
```

First time only:

```bash
cp /opt/cubechat-id/deploy/cubechat-id.service /opt/cubechat-id/deploy/cubechat-id-backup.service /opt/cubechat-id/deploy/cubechat-id-backup.timer /etc/systemd/system/
apt-get install -y sqlite3
systemctl daemon-reload && systemctl enable --now cubechat-id cubechat-id-backup.timer
```

After an update: `systemctl restart cubechat-id`.

## Caddy

One Caddy serves push, the relay and this. Diff `/etc/caddy/Caddyfile`
against `push/deploy/Caddyfile` first, back the live one up to
`/root/Caddyfile.<date>`, copy the repo one, then
`caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy`.
Check all three afterwards:

```bash
curl -s https://push.cubechat.tech/health
curl -sI https://relay.cubechat.tech
curl -s https://id.cubechat.tech/health
```

## Moderation

A key banned through the Telegram bot loses its name within a minute (the
service re-reads push's `banned.json`). To revoke an offensive name without a
ban:

```bash
. /opt/cubechat-id/.env
curl -s -X POST http://127.0.0.1:8090/admin/revoke -H "Authorization: Bearer $ADMIN_TOKEN" -d '{"name":"x","reason":"offensive"}'
```

Backups: `/root/backups/cubechat-id/names-YYYY-MM-DD.db`, 14 days.
