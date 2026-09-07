from pathlib import Path
from PIL import Image
import json,zipfile,hashlib
root=Path(__file__).resolve().parent;base=root.parent/'matcha-motion-v5'
items=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
verified=[]
for item in items:
 stem=item['id']
 for suffix in ['.png']:
  assert hashlib.sha256((root/(stem+suffix)).read_bytes()).digest()==hashlib.sha256((base/(stem+suffix)).read_bytes()).digest(),stem+' changed still'
 for suffix in ['.webp','.gif']:
  with Image.open(root/(stem+suffix)) as im:
   total=0
   for fi in range(im.n_frames):
    im.seek(fi);im.load();total+=im.info.get('duration',0)
    if suffix=='.webp':
     rgba=im.convert('RGBA');assert rgba.getpixel((0,0))[3]==0,(stem,fi,'corner not transparent')
   assert total==6000,(stem,suffix,total)
   assert im.n_frames>=20,(stem,suffix,im.n_frames)
   verified.append({'file':stem+suffix,'frames':im.n_frames,'duration_ms':total,'size':list(im.size)})
(root/'validation-preview.json').write_text(json.dumps(verified,indent=2),encoding='utf-8')
with zipfile.ZipFile(root/'matcha-motion-revised-72.zip','w',zipfile.ZIP_DEFLATED) as out:
 for item in items:
  for suffix in ['.webp','.gif','.png']:out.write(root/(item['id']+suffix),item['id']+suffix)
  for folder,suffix in [('png-2k','.png'),('webm-2k','.webm')]:out.write(root/folder/(item['id']+suffix),folder+'/'+item['id']+suffix)
 for name in ['README.md','manifest.json','prompts.json','validation-preview.json','validation-2k.json']:out.write(root/name,name)
 html=(root/'index.html').read_text(encoding='utf-8').replace('<a class="pill" href="compare.html">Сравнить движения</a>','').replace('<a class="pill" href="../matcha-motion/index.html">Самые первые 8</a>','')
 out.writestr('index.html',html)
with zipfile.ZipFile(root/'matcha-motion-revised-72.zip') as archive:
 assert archive.testzip() is None
 assert len(archive.namelist())==366,len(archive.namelist())
result={'revised_animations':len(items),'verified_media':len(verified),'unchanged_stills':72,'cycle_ms':6000,'archive_mb':round((root/'matcha-motion-revised-72.zip').stat().st_size/1048576,1),'zip_crc':'pass'}
(root/'validation-summary.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2))
