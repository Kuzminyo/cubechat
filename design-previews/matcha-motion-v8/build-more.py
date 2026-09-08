from pathlib import Path
import json,sys,importlib.util
from PIL import Image,ImageDraw
import numpy as np
r=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('drawn',r/'build-inbetweens.py');drawn=importlib.util.module_from_spec(spec);spec.loader.exec_module(drawn)
meta=json.loads((r/'more-batches.json').read_text(encoding='utf-8'))
items=json.loads((r/'manifest.json').read_text(encoding='utf-8'))
for batch in meta:
 n=batch['batch'];p=r/'sources'/('more-'+str(n)+'.png')
 if not p.exists() or (len(sys.argv)>1 and str(n) not in sys.argv[1:]):continue
 sheet=Image.open(p);w,h=sheet.size
 for row,stem in enumerate(batch['ids']):
  pose_dir=r/('corrected-poses' if (r/'corrected-poses'/(stem+'-0.png')).exists() else 'original-poses')
  originals=[Image.open(pose_dir/(stem+'-'+str(k)+'.png')).convert('RGBA') for k in range(4)];frames=[]
  for col in range(4):
   a=originals[col];b=originals[(col+1)%4];selected={'emoji-shush':[0,1,2,0],'cat-morning':[1,1,2,3],'cat-recover':[0,2,2,3]}.get(stem,[0,1,2,3]);sc=selected[col];im=drawn.key(sheet.crop((round(sc*w/4),round(row*h/len(batch['ids'])),round((sc+1)*w/4),round((row+1)*h/len(batch['ids'])))));im=im.crop(drawn.bbox(im));target=(np.array(drawn.bbox(a))+np.array(drawn.bbox(b)))/2
   scale=min((target[2]-target[0])/im.width,(target[3]-target[1])/im.height);im=im.resize((round(im.width*scale),round(im.height*scale)),Image.Resampling.LANCZOS);canvas=Image.new('RGBA',(512,512));canvas.alpha_composite(im,(round((target[0]+target[2]-im.width)/2),round(target[3]-im.height)));canvas.save(r/'inbetweens'/(stem+'-mid-'+str(col)+'.png'));frames.extend([a,canvas])
  frames[0].save(r/(stem+'.png'));frames[0].save(r/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=[1050,450]*4,loop=0,quality=96,method=2,alpha_quality=100)
  contact=Image.new('RGB',(1000,520),'#f4f3ea');d=ImageDraw.Draw(contact)
  for i,im in enumerate(frames):
   bg=Image.new('RGBA',(512,512),'#f4f3ea' if i%2==0 else '#20251f');bg.alpha_composite(im);contact.paste(bg.resize((235,235)).convert('RGB'),(i%4*250,i//4*260));d.text((i%4*250+6,i//4*260+237),'ORIGINAL' if i%2==0 else 'NEW INBETWEEN',fill='#6b745d')
  contact.save(r/(stem+'-contact.jpg'),quality=88)
  for item in items:
   if item['id']==stem:item.update({'render_pose_source':pose_dir.name,'revision_status':'inbetweens_added','drawn_frames':8,'original_frames_unchanged':4,'new_inbetweens':len(set(selected)),'selected_source_columns':selected,'duration_ms':6000,'method':'original key poses plus new drawn intermediate frames; no optical flow or layer rig'})
  print(stem+': 4 original + 4 drawn intermediate poses',flush=True)
(r/'manifest.json').write_text(json.dumps(items,ensure_ascii=False,indent=2),encoding='utf-8')
