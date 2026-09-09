# cubechat relay

Our own Nostr relay, on the droplet that already runs the push doorbell.

## Why

The app has three publishing lanes and the media one is the reason this exists.
A photo is tens of relay events; a circle is a few dozen; a file can be hundreds.
Public relays rate-limit per connection and answer a burst by throttling
everything in it — including the sentence somebody typed after the picture — and
they prune on their own schedule, so a chunk can be gone before the receiver
asks for it.

`relay_settings_controller.dart` already splits the lanes across separate public
relays for exactly that reason. This replaces the *media* lane's borrowed
sockets with ones we own, where the limits are ours to set and the retention is
long enough to outlive a transfer.

## What it is not

Not a public relay, and not a place anything is stored in the clear. Everything
the app publishes is a kind-1059 gift-wrapped frame: the relay sees a ciphertext,
a recipient tag and a timestamp. That is the same metadata every public relay in
the list already sees, which is why moving to our own is a straight improvement
and not a new exposure — one fewer stranger holding it.

It does mean **we** hold it. The honest reading: cubechat's operator can see
which npub sent how much to which npub and when, on the media lane. The mesh
still leaks none of that, and the relay lanes always leaked it to somebody.

## What runs where

The droplet already has Caddy in front and systemd behind it, with the push
doorbell on `127.0.0.1:8080`. The relay is the same shape one port along.

| | |
|---|---|
| binary | `strfry`, built from source into `/opt/cubechat-relay` |
| data | `/opt/cubechat-relay/strfry-db` (LMDB) |
| listens | `127.0.0.1:8081` |
| public name | `wss://relay.cubechat.tech`, terminated by Caddy |
| unit | `cubechat-relay.service` |
| config | `strfry.conf` in this directory |

`strfry` rather than a general-purpose relay because of one line in its config:
a retention policy. A relay carrying media chunks fills a disk, and this is the
only one of the usual choices that expires them without a cron job of our own.

## Putting it there

Every command runs on the droplet as root. **Nothing here touches the push
server**; if a step wants to, stop and say so.

### 1. Swap, because the build needs more RAM than the droplet has

strfry links a C++ binary and wants about 2 GB. A 1 GB droplet without swap gets
through most of it and is then killed, which looks like the compiler crashing
for no reason. Skip this only if `free -m` already shows swap.

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### 2. Build it

```bash
apt update && apt install -y git build-essential libyaml-perl libtemplate-perl libregexp-grammars-perl libssl-dev zlib1g-dev liblmdb-dev libflatbuffers-dev libsecp256k1-dev libzstd-dev
git clone https://github.com/hoytech/strfry /opt/strfry-src && cd /opt/strfry-src
git submodule update --init && make setup-golpe && make -j2
```

Twenty minutes on two cores. It is done when `/opt/strfry-src/strfry` exists.

### 3. Install it

```bash
useradd --system --home /opt/cubechat-relay --shell /usr/sbin/nologin cubechat-relay
mkdir -p /opt/cubechat-relay/strfry-db
install -m 755 /opt/strfry-src/strfry /usr/local/bin/strfry
chown -R cubechat-relay:cubechat-relay /opt/cubechat-relay
```

Then copy `strfry.conf` and `cubechat-relay.service` from this directory:

```powershell
scp relay/deploy/strfry.conf root@209.38.225.225:/opt/cubechat-relay/strfry.conf
scp relay/deploy/cubechat-relay.service root@209.38.225.225:/etc/systemd/system/cubechat-relay.service
```

Note the trailing filename on both. `scp file dest/` where `dest` exists copies
*into* it — that is how a push deploy once landed in
`/opt/cubechat-push/push/` and the server ran the old code for a day.

```bash
chown cubechat-relay:cubechat-relay /opt/cubechat-relay/strfry.conf
systemctl daemon-reload && systemctl enable --now cubechat-relay
systemctl status cubechat-relay --no-pager
```

### 4. A name and a certificate

One A record: `relay.cubechat.tech` → `209.38.225.225`. The apex stays on
GitHub Pages for the marketing site and is not touched, exactly as the push
deploy note says.

Then add the block from `deploy/Caddyfile.fragment` to `/etc/caddy/Caddyfile`
— **append it, do not replace the file**, the push server's blocks are in there
— and reload:

```bash
systemctl reload caddy
```

### 5. Check it from your own machine

```powershell
curl.exe -s -H "Accept: application/nostr+json" https://relay.cubechat.tech
```

That is the NIP-11 document. A JSON blob naming the relay means the whole chain
works: DNS, Caddy, the certificate, the socket and strfry. Anything else and the
part that failed is the part that answered.

## Then, in the app

`RelaySettings.defaultMediaUrls` gains `wss://relay.cubechat.tech` **first**,
with the public pair kept behind it. Not replaced by it: one relay is one
machine, and a media transfer that can only go one way is a transfer that stops
when that machine reboots.
