from pathlib import Path
import sys,importlib.util,json,shutil
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import cv2,numpy as np
from PIL import Image,ImageDraw
r=Path('D:/projects/cubechat/design-previews/matcha-motion-v8');spec=importlib.util.spec_from_file_location('old',r.parent/'matcha-motion-v6/build-motion.py');old=importlib.util.module_from_spec(spec);spec.loader.exec_module(old)
p=r.parent/'matcha-motion-v6/sources/exec-ec54c912-9602-449b-bb01-353a01d35fdd.png';sheet=old.remove_background(Image.open(p),True);w,h=sheet.size;a=np.array(sheet.getchannel('A'));boundaries=[0]
for q in range(1,6):
 guess=round(h*q/6);radius=round(h/6*.20);boundaries.append(min(range(guess-radius,guess+radius+1),key=lambda y:np.count_nonzero(a[y]>128)))
boundaries.append(h);row=sheet.crop((0,boundaries[4],w,boundaries[5]));arr=np.array(row);n,l,stats,_=cv2.connectedComponentsWithStats(np.uint8(arr[:,:,3]>40),8);body=[i for i in range(1,n) if stats[i,4]>1000];body.sort(key=lambda i:stats[i,0]);print(json.dumps({'sheet':str(p),'row_bounds':boundaries[4:6],'bodies':[stats[i].tolist() for i in body]}));assert len(body)==4
contact=Image.new('RGB',(1040,290),'#20251f');d=ImageDraw.Draw(contact)
for j,i in enumerate(body):
 x,y,bw,bh,_=stats[i];im=row.crop((x,y,x+bw,y+bh));im.thumbnail((245,240));contact.paste(im,(j*260,0),im);d.text((j*260+5,260),'COMPLETE SOURCE POSE '+str(j),fill='white')
contact.save(r/'tired-source-extraction.jpg',quality=90)

# Keep the archived key poses byte-identical. Correct extraction is a separate
# input, with the same pixel scale and resting baseline as the old drawing.
dest=r/'corrected-poses';dest.mkdir(exist_ok=True)
old0=Image.open(r/'original-poses/cat-tired-0.png').convert('RGBA');bb=old0.getchannel('A').point(lambda v:255 if v>80 else 0).getbbox();scale=(bb[3]-bb[1])/stats[body[0],3]
for j,i in enumerate(body):
 x,y,bw,bh,_=stats[i];im=row.crop((x,y,x+bw,y+bh));im=im.resize((round(bw*scale),round(bh*scale)),Image.Resampling.LANCZOS);canvas=Image.new('RGBA',(512,512));canvas.alpha_composite(im,((512-im.width)//2,bb[3]-im.height));canvas.save(dest/('cat-tired-'+str(j)+'.png'))
shutil.copy2(p,r/'sources/tired-original-sheet.png')
(r/'tired-repair.json').write_text(json.dumps({'source_sheet':p.name,'problem':'fixed 256px grid cut tails into neighboring cells','fix':'extract complete connected source drawings; preserve common scale and baseline','source_key_archive_unchanged':True,'corrected_pose_count':4},indent=2),encoding='utf-8')
