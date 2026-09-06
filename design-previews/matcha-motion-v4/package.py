from pathlib import Path
from PIL import Image
import json,zipfile,re
root=Path(__file__).resolve().parent
items=[x for x in json.loads((root/'manifest.json').read_text(encoding='utf-8')) if x.get('added_in')=='04']
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
html=(root/'index.html').read_text(encoding='utf-8-sig')
html=re.sub(r'<button class="card (?:cat|emoji)" data-new="false"[\s\S]*?</button>','',html)
html=re.sub(r'<button class="pill" id="filter-new"[\s\S]*?</button>','',html)
html='\n'.join(line for line in html.splitlines() if "document.getElementById('filter-new').onclick" not in line)
html=html.replace('56 анимаций','16 анимаций').replace('28 стикеров','8 стикеров').replace('28 реакций','8 реакций').replace('Ещё 16 эмоций. Всего — 56.','16 новых эмоций в спокойном ритме.')
html=html.replace('<a class="pill solid" href="matcha-new-16-v4.zip" download>Скачать новые 16</a>','')
html=html.replace('<a class="pill" href="../matcha-motion-v3/index.html">Предыдущие 40</a>','')
(root/'additions.html').write_text(html,encoding='utf-8')
validation=json.loads((root/'validation-2k.json').read_text(encoding='utf-8'))
ids={x['id'] for x in items}
with zipfile.ZipFile(root/'matcha-new-16-v4.zip','w',zipfile.ZIP_DEFLATED) as out:
 for item in items:
  for suffix in ['.webp','.gif','.png']:
   path=root/(item['id']+suffix);out.write(path,path.name)
  for directory,suffix in [('png-2k','.png'),('webm-2k','.webm')]:
   path=root/directory/(item['id']+suffix);out.write(path,directory+'/'+path.name)
 for name in ['README.md','validation-preview.json','prompts.json']:out.write(root/name,name)
 out.writestr('manifest.json',json.dumps(items,ensure_ascii=False,indent=2))
 out.writestr('validation-2k.json',json.dumps([x for x in validation if x['id'] in ids],indent=2))
 out.writestr('index.html',html)
with zipfile.ZipFile(root/'matcha-new-16-v4.zip') as check:
 assert check.testzip() is None
 assert len(check.namelist())==86,len(check.namelist())
print(json.dumps({'new_animations':16,'total_collection':56,'archive_mb':round((root/'matcha-new-16-v4.zip').stat().st_size/1048576,1),'archive_entries':86},indent=2))

