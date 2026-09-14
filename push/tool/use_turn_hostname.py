from pathlib import Path
import shutil
path = Path('/opt/cubechat-push/.env')
backup = path.with_name('.env.before-turn-hostname-20260914')
if not backup.exists():
    shutil.copy2(path, backup)
    backup.chmod(0o600)
lines = path.read_text().splitlines()
if not any(line.startswith('TURN_URLS=') for line in lines):
    raise SystemExit('TURN_URLS missing; refusing to alter an unknown configuration')
urls = 'TURN_URLS=turn:push.cubechat.tech:3478?transport=udp,turn:push.cubechat.tech:3478?transport=tcp'
path.write_text('\n'.join(urls if line.startswith('TURN_URLS=') else line for line in lines) + '\n')
print('TURN now advertises its verified DNS name; secret unchanged')

