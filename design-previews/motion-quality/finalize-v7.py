from pathlib import Path
import json,hashlib,zipfile
from html.parser import HTMLParser
from urllib.parse import urlsplit,unquote
from PIL import Image
r=Path('D:/projects/cubechat/design-previews');q=r/'motion-quality';v=r/'matcha-motion-v7'
items=json.loads((v/'manifest.json').read_text(encoding='utf-8'))
checks=json.loads((q/'collection-validation.json').read_text(encoding='utf-8'))
assert len(items)==len(checks)==72
assert all(x['duration_ms']==6000 and x['edge_alpha_max']==0 for x in checks),[x for x in checks if x['edge_alpha_max']!=0]
for item in items:
 stem=item['id'];source=q/(item['kind']+'-rig')/(stem+'.webp')
 assert hashlib.sha256(source.read_bytes()).digest()==hashlib.sha256((v/(stem+'.webp')).read_bytes()).digest(),stem
 for sub,suffix in [('', '.webp'),('', '.gif'),('', '.png'),('png-2k','.png'),('webm-2k','.webm')]:assert (v/sub/(stem+suffix)).stat().st_size>0
 im=Image.open(v/'png-2k'/(stem+'.png'));assert im.size==(2048,2048) and im.mode=='RGBA'
 gif=Image.open(v/(stem+'.gif'));duration=0
 for i in range(gif.n_frames):gif.seek(i);duration+=gif.info.get('duration',0)
 assert duration==6000,(stem,duration)
qa2k=json.loads((v/'validation-2k-cat.json').read_text())+json.loads((v/'validation-2k-emoji.json').read_text())
assert len({x['id'] for x in qa2k})==72
browser=json.loads((v/'validation-browser.json').read_text());assert browser['passed']
(v/'validation-motion.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
plan=json.loads((q/'revision-plan.json').read_text(encoding='utf-8'))
for item in plan:item.update({'status':'implemented_and_reviewed','output':'../matcha-motion-v7/'+item['id']+'.webp'})
(q/'revision-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
(q/'STATUS.md').write_text('''# Version 07 — collection saved and verified

All 72 animation mockups (36 cats / 36 emoji) are in ../matcha-motion-v7/.
The earlier four-item prototype page is retained for diagnostic history;
open ../matcha-motion-v7/index.html for the complete new collection.

- No optical-flow or full-drawing mesh morphing in the new renderers.
- Stable core shapes; independently anchored hands, paws, props and facial details.
- 6-second loops; WebP 512, GIF 256, transparent PNG/WebM 2048 exports.
- Visual review: six phases per animation on light/dark backgrounds, large
  browser playback for cat/emoji, 32px/thumbnail samples and mobile layout.
- Files verified for complete duration, transparent margins, source/output
  equality and alpha in actual decoded VP9 video frames.
- 72-card gallery: pause/theme/modal/playback/close/mobile checks passed in Edge.

Design limits: illustration parts were redrawn in the earlier palette/style;
they are not pixel-identical to the previous drawings. 2K is an upscale.
These remain reviewable sticker mockups, not Flutter or Telegram TGS integration.
''',encoding='utf-8')
archive=v/'matcha-motion-v7-72.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=1) as z:
 for p in sorted(v.rglob('*')):
  if p.is_file() and p!=archive and p.name!='validation-package.json':z.write(p,p.relative_to(v).as_posix())
with zipfile.ZipFile(archive) as z:assert z.testzip() is None;entries=len(z.infolist())
missing=[]
class Links(HTMLParser):
 def handle_starttag(self,tag,attrs):
  for key,value in attrs:
   if key in ['href','src'] and value and not urlsplit(value).scheme and not value.startswith('#'):
    target=(self.base/unquote(value.split('?')[0])).resolve()
    if not target.exists():missing.append(str(target))
for p in v.glob('*.html'):
 parser=Links();parser.base=v;parser.feed(p.read_text(encoding='utf-8'))
assert not missing,missing
report={'animations':72,'cats':36,'emoji':36,'cycle_ms':6000,'transparent_margins':True,'webm_2k_verified':72,'png_2k_verified':72,'gif_duration_verified':72,'source_output_hashes_match':True,'browser_passed':True,'missing_local_links':missing,'zip_crc_passed':True,'zip_entries':entries,'zip_mb':round(archive.stat().st_size/1048576,1),'upscaled_2k':True}
(v/'validation-package.json').write_text(json.dumps(report,indent=2),encoding='utf-8');print(json.dumps(report,ensure_ascii=False),flush=True)
