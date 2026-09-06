from pathlib import Path
from PIL import Image
import json,zipfile
root=Path(__file__).resolve().parent
items=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
verified=[]
for item in items:
 for suffix in ['.webp','.gif']:
  path=root/(item['id']+suffix)
  with Image.open(path) as im:
   total=0
   for frame in range(im.n_frames):
    im.seek(frame);im.load();total+=im.info.get('duration',0)
   assert total==4000,(path,total)
   assert im.n_frames>40,(path,im.n_frames)
   verified.append({'file':path.name,'frames':im.n_frames,'duration_ms':total})
(root/'validation-preview.json').write_text(json.dumps(verified,indent=2),encoding='utf-8')
with zipfile.ZipFile(root/'matcha-2k-pack-v3.zip','w',zipfile.ZIP_DEFLATED) as out:
 for item in items:
  for suffix in ['.webp','.gif','.png']:
   path=root/(item['id']+suffix);out.write(path,path.name)
  for directory,suffix in [('png-2k','.png'),('webm-2k','.webm')]:
   path=root/directory/(item['id']+suffix);out.write(path,directory+'/'+path.name)
 for name in ['manifest.json','README.md','validation-2k.json','validation-preview.json','prompts.json']:
  out.write(root/name,name)
 html=(root/'index.html').read_text(encoding='utf-8-sig')
 html=html.replace('<a class="pill" href="../matcha-motion-v2/index.html">Коллекция 02</a>','')
 out.writestr('index.html',html)
with zipfile.ZipFile(root/'matcha-2k-pack-v3.zip') as check:
 assert check.testzip() is None
 assert len(check.namelist())==206,len(check.namelist())
print(json.dumps({'animations':40,'verified_preview_files':80,'archive_mb':round((root/'matcha-2k-pack-v3.zip').stat().st_size/1048576,1),'archive_entries':206},indent=2))

