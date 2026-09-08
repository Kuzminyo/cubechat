from pathlib import Path
import json,hashlib,zipfile,re,time
from PIL import Image
r=Path(__file__).resolve().parent;items=json.loads((r/'manifest.json').read_text(encoding='utf-8'));assert len(items)==72
assert len(json.loads((r/'validation-exports.json').read_text(encoding='utf-8')))==72
records=[]
for x in items:
 stem=x['id'];assert x['revision_status']=='inbetweens_added'
 for suffix in ['.webp','.gif','.png','-contact.jpg']:assert (r/(stem+suffix)).exists(),stem+suffix
 for folder,suffix in [('png-2k','.png'),('webm-2k','.webm')]:assert (r/folder/(stem+suffix)).stat().st_size>1000
 durations={}
 for fmt in ['webp','gif']:
  im=Image.open(r/(stem+'.'+fmt));d=0
  for i in range(im.n_frames):im.seek(i);im.load();d+=im.info['duration']
  assert d==6000,(stem,fmt,d);durations[fmt]=d
 im=Image.open(r/(stem+'.webp'));assert im.size==(512,512) and im.convert('RGBA').getchannel('A').getextrema()==(0,255)
 assert Image.open(r/'png-2k'/(stem+'.png')).size==(2048,2048)
 for i in range(4):
  p=r/'original-poses'/(stem+'-'+str(i)+'.png');assert p.read_bytes()==(r.parent/'matcha-motion-v6/poses'/p.name).read_bytes()
 records.append({'id':stem,'new_drawings':x['new_inbetweens'],'duration_ms':durations,'formats_verified':5,'source_keys_unchanged':4})
(r/'validation-collection.json').write_text(json.dumps(records,indent=2),encoding='utf-8')
archive=r/'matcha-motion-v8-72.zip';files=[p for p in r.rglob('*') if p.is_file() and p.suffix!='.zip' and '__pycache__' not in p.parts]
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=1) as z:
 for p in files:z.write(p,Path(r.name)/p.relative_to(r))
with zipfile.ZipFile(archive) as z:
 assert z.testzip() is None
 for x in items:
  for suffix in ['.webp','.gif','.png']:assert z.read(r.name+'/'+x['id']+suffix)==(r/(x['id']+suffix)).read_bytes()
report={'stickers':72,'new_drawings':sum(x['new_inbetweens'] for x in items),'unchanged_originals':288,'exports_2k':72,'archive_mb':round(archive.stat().st_size/1024/1024,1),'archive_entries':len(files),'sha256':hashlib.sha256(archive.read_bytes()).hexdigest()};(r/'completion.json').write_text(json.dumps(report,indent=2),encoding='utf-8');print(json.dumps(report),flush=True)
