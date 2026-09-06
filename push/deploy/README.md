# Putting it on the droplet

The droplet is `209.38.225.225` (`10.19.0.5` on the VPC, which nothing here
needs — the relays and Apple are both on the public side). Ubuntu 24.04.

## The domain

`push.cubechat.tech`. One A record:

| Type | Host   | Value            |
|------|--------|------------------|
| A    | `push` | `209.38.225.225` |

Nothing else in the zone is touched — the apex stays on GitHub Pages for the
marketing site. Caddy gets the certificate from Let's Encrypt on first start
once the record answers.

**No new domain is needed for this.** A subdomain of one already owned costs
nothing and is the same amount of work as a fresh registration would be.

`cubechat.qpon` was the original plan and is abandoned: the registrar's panel
had the domain and an A record for `wake`, but the registry did not have the
domain at all, so no resolver on earth could find it —

```
$ nslookup -type=NS cubechat.qpon a.nic.qpon
*** Non-existent domain
```

`209-38-225-225.sslip.io` was the stand-in while that was true, and it still
answers, so the app keeps it as a second choice behind the real name. It is not
a good first choice: sslip.io maps any `a-b-c-d.sslip.io` to the address written
in the name, which is exactly the shape DNS rebinding protection blocks. On
2026-09-02 the developer's own machine returned "no such host" for it while
1.1.1.1 and 8.8.8.8 both answered. Drop it from the Caddyfile and from
`push_registration.dart` once no shipped build still asks for it.

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

## The Android half

Android registrations go to FCM instead of APNs, and FCM authenticates with a
Google service account rather than a `.p8`. One file, and the service picks it
up on its own — there is nothing to set in `.env`, because
`WorkingDirectory=/opt/cubechat-push` makes the default path resolve there.

Firebase console → the **cubechat-afdac** project → Settings → Service accounts
→ **Generate new private key**. It downloads a JSON file. That file is a
credential for sending pushes as this project: it never goes into git.

```powershell
scp D:\path\to\cubechat-afdac-*.json `
  root@209.38.225.225:/opt/cubechat-push/fcm-service-account.json
```

```bash
chown cubechat:cubechat /opt/cubechat-push/fcm-service-account.json
chmod 600 /opt/cubechat-push/fcm-service-account.json
systemctl restart cubechat-push
journalctl -u cubechat-push -n 5 --no-pager | grep fcm
```

The last line is the check: `service account for cubechat-afdac` means it read
the key. `no service account — Android push is off` means the file is not where
it is looking, and the service runs on happily ringing iPhones only.

The project has to be the same one `android/app/google-services.json` names.
A key from a different Firebase project authenticates fine and then answers
`404` for every token, which reads exactly like "the app was uninstalled".

```bash
chown -R cubechat:cubechat /opt/cubechat-push
chmod 600 /opt/cubechat-push/.env
cp deploy/cubechat-push.service /etc/systemd/system/
cp deploy/Caddyfile /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --now cubechat-push
systemctl reload caddy || systemctl restart caddy
```

The Caddyfile names `push.cubechat.tech` and the sslip.io address. Add the A
record **before** reloading Caddy, or it will fail the ACME challenge for the
new name and keep retrying until the record answers.

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
curl.exe -s https://push.cubechat.tech/health
```

`{"ok":true,"tokens":N,...}` — and `N` is the number that answers "is anybody
registered". A phone that has turned the switch on and reached the server moves
it; `tokens:0` with a healthy service means no registration has ever landed,
whatever the app appears to say. `ios` and `android` beside it split that count,
which is the only way to tell which half of a two-phone test actually arrived.

`{"ok":true,"tokens":0,"relays":["wss://nos.lol","wss://relay.primal.net"]}`
means the registry is empty, both relays are up, and it is waiting. That is the
whole of what "working" looks like until a phone registers.

An empty reply means nothing is listening — the service is not running, or
Caddy is not in front of it. Both show up in `systemctl status`.

## What the service keeps, and for how long

On disk it holds exactly one file of its own: `tokens.json`, the registry of
`npub -> device token`. That is the service. Everything else lives in memory
and dies with the process — the set of recently seen event ids is bounded at
five thousand and is never written down.

The journal is the exception, and it was the one worth fixing. Every event
writes a line naming a person:

```
[wake] a1b2c3d4 has mail
[apns] a1b2c3d4 -> production: 200
```

Eight characters of an npub beside a timestamp, kept until the disk fills.
The app tells its users that the doorbell *learns* who received something and
when; it never promised the server would write it down forever.

```bash
cp deploy/journald-cubechat.conf /etc/systemd/journald.conf.d/cubechat.conf
systemctl restart systemd-journald
journalctl --vacuum-time=3d          # drop what is already there
journalctl --disk-usage
```

Three days is what a bug report needs — every diagnosis this service has been
through was answered by lines minutes or hours old — and the 100M ceiling in
the same file is there so a burst cannot outrun the time limit.

**This is not a memory fix.** Measured on 2026-09-06 while the question was
being asked: the process sat at 46.3M with a peak of 72.8M after two days up,
`available` memory was 540M of 961M, disk 12% of 24G, and the memory graph was
a flat line. Nothing on this droplet is filling. What was accumulating was a
record of other people's traffic, which is a different problem and the one
worth acting on.

## The firewall

Only 80 and 443 need to be open. The service itself listens on 8080 and Caddy
reaches it over loopback, so it is not exposed.

```bash
ufw allow OpenSSH && ufw allow 80,443/tcp && ufw --force enable
```
