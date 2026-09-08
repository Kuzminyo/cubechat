from pathlib import Path
import json,importlib.util
from concurrent.futures import ThreadPoolExecutor,as_completed
r=Path('D:/projects/cubechat/design-previews/motion-quality');s=importlib.util.spec_from_file_location('cats',r/'build-cat-rig.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
unaffected={'cat-wave','cat-laugh','cat-sleep','cat-approve','cat-party','cat-cool','cat-tired','cat-morning','cat-hurry','cat-music'}
items=[x for x in m.ITEMS if x['id'] not in unaffected]
(r/'paw-fix-affected.json').write_text(json.dumps([x['id'] for x in items],indent=2),encoding='utf-8')
m.contact()
with ThreadPoolExecutor(max_workers=3) as pool:
 for f in as_completed([pool.submit(m.build,item) for item in items]):f.result()
print('Corrected front paws in '+str(len(items))+' animations',flush=True)
