from pathlib import Path
import importlib.util
r=Path('D:/projects/cubechat/design-previews/motion-quality');s=importlib.util.spec_from_file_location('cats',r/'build-cat-rig.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
for item in m.ITEMS:
 if item['id'] in ['cat-work','cat-waiting']:m.build(item)
