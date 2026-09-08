from pathlib import Path
from PIL import Image,ImageOps,ImageDraw
r=Path('D:/projects/cubechat/design-previews');out=Image.new('RGB',(1200,900),'#f4f3ea');d=ImageDraw.Draw(out)
for i,stem in enumerate(['emoji-hugging','emoji-clap','emoji-shush','emoji-salute','emoji-thinking','emoji-giggle','emoji-thanks','emoji-approve','emoji-heart','emoji-angel','emoji-zipper','emoji-mindblown']):
 im=Image.open(r/'matcha-motion-v6/masters'/(stem+'.png')).convert('RGBA');im=ImageOps.contain(im,(270,250));x=(i%4)*300+(300-im.width)//2;y=(i//4)*300;out.paste(im,(x,y),im);d.text(((i%4)*300+15,y+260),stem,fill='#30382a')
out.save(r/'motion-quality/emoji-props-reference.jpg',quality=88)
