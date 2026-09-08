from pathlib import Path
from PIL import Image,ImageOps,ImageDraw
r=Path('D:/projects/cubechat/design-previews');out=Image.new('RGB',(1000,700),'#f4f3ea');d=ImageDraw.Draw(out)
for i,stem in enumerate(['emoji-smile','emoji-laugh','emoji-love','emoji-surprise','emoji-sad','emoji-angry']):
 im=Image.open(r/'matcha-motion-v6/masters'/(stem+'.png')).convert('RGBA');im=ImageOps.contain(im,(300,290));x=(i%3)*333+(333-im.width)//2;y=(i//3)*350;out.paste(im,(x,y),im);d.text(((i%3)*333+20,y+310),stem,fill='#30382a')
out.save(r/'motion-quality/emoji-reference.jpg',quality=90)
