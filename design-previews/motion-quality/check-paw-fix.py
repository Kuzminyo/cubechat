from pathlib import Path
import importlib.util
from PIL import Image,ImageDraw
r=Path('D:/projects/cubechat/design-previews/motion-quality');s=importlib.util.spec_from_file_location('cats',r/'build-cat-rig.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
ids=['cat-shy','cat-hug','cat-love','cat-facepalm','cat-matcha','cat-flower']
out=Image.new('RGB',(1000,1000),'#f4f3ea');d=ImageDraw.Draw(out)
for row,stem in enumerate(ids):
 for col,fi in enumerate([0,28,50,70,105,135]):
  im=m.render(stem,fi);bg=Image.new('RGBA',(512,512),'#f4f3ea' if col%2==0 else '#20251f');bg.alpha_composite(im);out.paste(bg.resize((160,160)).convert('RGB'),(col*166,row*166))
 d.text((3,row*166+149),stem,fill='#69705b')
out.save(r/'paw-fix-contact.jpg',quality=89)
im=m.render('cat-shy',65);bg=Image.new('RGBA',(512,512),'#f4f3ea');bg.alpha_composite(im);bg.convert('RGB').save(r/'paw-fix-shy.jpg',quality=94)
