#!/usr/bin/env python3
"""Install the reviewed first-call configuration on the existing CubeChat host.
Run as root AFTER apt-get install coturn and staging push/src/index.js.
Secrets stay on the host; existing config and push source are backed up.
"""
from pathlib import Path
import os
import secrets
import shutil
import subprocess

base = Path('/opt/cubechat-push')
staged = base / 'src/index.turn-staged.js'
if not staged.is_file():
    raise SystemExit('Stage push/src/index.js as src/index.turn-staged.js first')
subprocess.run(['node', '--check', str(staged)], check=True)
subprocess.run(['systemctl', 'stop', 'coturn'], check=True)
secret_path = Path('/etc/turnserver.secret')
if not secret_path.exists():
    fd = os.open(str(secret_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write(secrets.token_hex(32))
secret = secret_path.read_text().strip()
if len(secret) < 32:
    raise SystemExit('Existing TURN secret too short')
config = Path('/etc/turnserver.conf')
env = base / '.env'
source = base / 'src/index.js'
for path in [config, env, source]:
    backup = path.with_name(path.name + '.before-turn-20260913')
    if path.exists() and not backup.exists():
        shutil.copy2(path, backup)
        if path == env or path == config:
            backup.chmod(0o600)
config.write_text('''listening-port=3478
listening-ip=209.38.225.225
relay-ip=209.38.225.225
realm=cubechat.tech
fingerprint
use-auth-secret
static-auth-secret=''' + secret + '''
min-port=49160
max-port=49200
total-quota=40
max-bps=128000
bps-capacity=5120000
stale-nonce=600
no-tls
no-dtls
no-tcp-relay
no-cli
no-multicast-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=224.0.0.0-255.255.255.255
syslog
''')
# Two lines this config used to carry, and must not carry again.
#
# `denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff` was meant to
# refuse IPv6 peers. coturn compares an IPv4 peer through its IPv4-mapped IPv6
# form, and that range is the whole address space, so it refused every peer at
# all: measured on the droplet, a client-to-client relay through this server got
# "403 Forbidden IP" and the log named that exact range. Every call relayed
# here would have failed at connect with nothing on the phone to say why. The
# relay socket is IPv4 (relay-ip above), so it cannot reach an IPv6 peer anyway.
#
# `no-loopback-peers` is not an option coturn 4.6 knows ("Bad configuration
# format" in the log). Loopback is refused by the explicit 127.0.0.0 range
# above, verified: a peer of 127.0.0.1 still gets 403 after the removal.
shutil.chown(config, user='root', group='turnserver')
config.chmod(0o640)
lines = [line for line in env.read_text().splitlines()
         if not line.startswith(('TURN_SECRET=', 'TURN_URLS='))]
lines += ['TURN_SECRET=' + secret,
          'TURN_URLS=turn:209.38.225.225:3478?transport=udp,turn:209.38.225.225:3478?transport=tcp']
env.write_text('\n'.join(lines) + '\n')
env.chmod(0o600)
shutil.copy2(staged, source)
subprocess.run(['systemctl', 'enable', '--now', 'coturn'], check=True)
subprocess.run(['systemctl', 'is-active', 'coturn'], check=True)
for port in ['3478/udp', '3478/tcp', '49160:49200/udp']:
    subprocess.run(['ufw', 'allow', port], check=True)
subprocess.run(['systemctl', 'restart', 'cubechat-push'], check=True)
print('TURN and push configured; secrets not printed. Verify HTTPS and allocations next.')

