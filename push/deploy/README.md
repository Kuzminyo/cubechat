# Putting it on the droplet

The droplet is `209.38.225.225` (`10.19.0.5` on the VPC, which nothing here
needs — the relays and Apple are both on the public side). Ubuntu 24.04.

## The domain, and why it is not in the way

`cubechat.qpon` is **not delegated in the `.qpon` registry**. Asked the zone's
own nameserver directly:

```
$ nslookup -type=NS cubechat.qpon a.nic.qpon
*** Non-existent domain
```

The registrar's panel has the domain and an A record for `wake`; the registry
does not have the domain at all, so no resolver on earth can find it. Nothing on
this side can fix that — the nameservers have to reach the registry, which is a
question for the registrar.

It does not have to hold anything up. `209-38-225-225.sslip.io` resolves to the
droplet today and Let's Encrypt issues for it, so the service can be finished,
deployed and pointed at from the app while the domain is sorted out. Moving to
`wake.cubechat.qpon` later is one line in the Caddyfile and one string in the
app.

## Getting the files there

From the Windows machine, in PowerShell:

```powershell
scp -r D:\projects\cubechat\push root@209.38.225.225:/opt/cubechat-push
```

## On the droplet

Neither Node 20+ nor Caddy is in Ubuntu 24.04's own archive — `apt install
nodejs` gives 18, which is below what `package.json` asks for, and `apt install
caddy` finds nothing at all. Both come from their projects' repositories:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs debian-keyring debian-archive-keyring apt-transport-https

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy
```

Then the service:

```bash
adduser --system --group --home /opt/cubechat-push cubechat
cd /opt/cubechat-push && npm install --omit=dev
cp .env.example .env
```

Put `AuthKey.p8` beside it and fill in `.env` — the key id from the `.p8`
filename, the team id (`XGPPT9GNR2`) and the topic (`app.cubechat`).

```bash
chown -R cubechat:cubechat /opt/cubechat-push
chmod 600 /opt/cubechat-push/.env
cp deploy/cubechat-push.service /etc/systemd/system/
cp deploy/Caddyfile /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --now cubechat-push
systemctl reload caddy || systemctl restart caddy
```

The Caddyfile names `wake.cubechat.qpon` as well as the sslip.io address. Caddy
will keep trying to get a certificate for a name that does not resolve and log
about it; that is expected until the registry has the domain, and it does not
stop the other name from working.

## Checking it

On the droplet:

```bash
systemctl status cubechat-push --no-pager
journalctl -u cubechat-push -n 30 --no-pager
curl -s localhost:8080/health
```

Through Caddy, from anywhere — and on Windows it must be `curl.exe`, because
PowerShell's `curl` is an alias for `Invoke-WebRequest` and does not take `-s`:

```powershell
curl.exe -s https://209-38-225-225.sslip.io/health
```

`{"ok":true,"tokens":0,"relays":["wss://nos.lol","wss://relay.primal.net"]}`
means the registry is empty, both relays are up, and it is waiting. That is the
whole of what "working" looks like until a phone registers.

An empty reply means nothing is listening — the service is not running, or
Caddy is not in front of it. Both show up in `systemctl status`.

## The firewall

Only 80 and 443 need to be open. The service itself listens on 8080 and Caddy
reaches it over loopback, so it is not exposed.

```bash
ufw allow OpenSSH && ufw allow 80,443/tcp && ufw --force enable
```
