from pathlib import Path
import json,zipfile
root=Path(__file__).resolve().parent
items=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
with zipfile.ZipFile(root/'matcha-animated-pack-v2.zip','w',zipfile.ZIP_DEFLATED) as out:
 for item in items:
  for ext in ['.webp','.gif','.png']:
   path=root/(item['id']+ext);out.write(path,path.name)
 for name in ['manifest.json','README.md','validation.json','prompts.json']:
  out.write(root/name,name)
 html=(root/'index.html').read_text(encoding='utf-8-sig')
 html=html.replace('<a class="pill" href="../matcha-motion/index.html">Первая версия</a>','')
 out.writestr('index.html',html)
with zipfile.ZipFile(root/'matcha-animated-pack-v2.zip') as check:
 assert check.testzip() is None
 assert len(check.namelist())==77
print(json.dumps({'archive_mb':round((root/'matcha-animated-pack-v2.zip').stat().st_size/1048576,1),'entries':77}))

