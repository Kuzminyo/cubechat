from pathlib import Path
import runpy
from PIL import Image
root=Path('D:/projects/cubechat/design-previews/motion-quality');mod=runpy.run_path(str(root/'build-rig-prototype.py'))
out=Image.new('RGB',(1200,800),'#f4f3ea')
for row,stem in enumerate(['cat-morning','cat-laugh','cat-flower','cat-victory']):
 for col,fi in enumerate([0,35,55,75,105,135]):
  frame=mod['render'](stem,fi);bg=Image.new('RGBA',frame.size,'#f4f3ea');bg.alpha_composite(frame);out.paste(bg.resize((200,200)).convert('RGB'),(col*200,row*200))
out.save(root/'rig-refined-contact.jpg',quality=90)
print('Refined joint contact sheet rendered')
