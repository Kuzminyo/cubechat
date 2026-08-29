# Putting it on the droplet

The droplet is `209.38.225.225` (`10.114.0.2` on the VPC, which nothing here
needs — the relays and Apple are both on the public side).

## The domain, and why it is not in the way

`cubechat.qpon` is **not delegated in the `.qpon` registry**. Asked directly:

```
$ nslookup -type=NS cubechat.qpon a.nic.qpon
*** Non-existent domain
```

The registrar's panel has the domain and the A record for `wake`; the registry
does not have the domain at all. Nothing on this side can fix that — the
nameservers have to reach the registry, which is a registrar question.

It does not have to hold anything up. `209-38-225-225.sslip.io` resolves to the
droplet today and Let's Encrypt issues for it, so the service can be finished,
deployed and pointed at from the app while the domain is sorted out. Moving to
`wake.cubechat.qpon` later is one line in the Caddyfile and one string in the
app.

## Steps

```bash
ssh root@209.38.225.225
```

```bash
apt update && apt install -y nodejs npm caddy
adduser --system --group --home /opt/cubechat-push cubechat
```

Copy `push/` to `/opt/cubechat-push`, then:

```bash
cd /opt/cubechat-push && npm install --omit=dev
```

Put `AuthKey.p8` beside it and fill in `.env` from `.env.example` — the key id,
the team id (`XGPPT9GNR2`) and the topic (`app.cubechat`).

```bash
chown -R cubechat:cubechat /opt/cubechat-push
chmod 600 /opt/cubechat-push/AuthKey.p8 /opt/cubechat-push/.env
cp deploy/cubechat-push.service /etc/systemd/system/
cp deploy/Caddyfile /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --now cubechat-push caddy
```

## Checking it before the app exists

```bash
curl -s https://209-38-225-225.sslip.io/health
```

`{"ok":true,"tokens":0,"relays":["wss://nos.lol","wss://relay.primal.net"]}`
means the registry is empty, both relays are up, and it is waiting. That is the
whole of what "working" looks like until a phone registers.

`journalctl -u cubechat-push -f` shows a line per registration and a line per
wake.

## The firewall

Only 80 and 443 need to be open. The service itself listens on 8080 bound
through Caddy on loopback and is not reachable from outside.

```bash
ufw allow 80,443/tcp && ufw enable
```
