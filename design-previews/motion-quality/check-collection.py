from pathlib import Path
from PIL import Image,ImageDraw
import json,numpy as np
r=Path('D:/projects/cubechat/design-previews/motion-quality');out=r/'qa';out.mkdir(exist_ok=True)
items=json.loads((r.parent/'matcha-motion-v6/manifest.json').read_text(encoding='utf-8'))
reports=[]
for kind in ['emoji','cat']:
 selected=[x for x in items if x['kind']==kind and (r/(kind+'-rig')/(x['id']+'.webp')).exists()]
 for start in range(0,len(selected),12):
  sheet=Image.new('RGB',(1100,1200),'#f4f3ea');d=ImageDraw.Draw(sheet)
  for row,item in enumerate(selected[start:start+12]):
   im=Image.open(r/(kind+'-rig')/(item['id']+'.webp'));duration=0;frames=[];edge=0
   for f in range(im.n_frames):
    im.seek(f);fr=im.convert('RGBA');a=np.array(fr.getchannel('A'));edge=max(edge,int(max(a[0].max(),a[-1].max(),a[:,0].max(),a[:,-1].max())));frames.append((duration,fr.copy()));duration+=im.info.get('duration',40)
   aa=[]
   for source in [frames[0][1],frames[-1][1]]:
    bg=Image.new('RGBA',(512,512),'#252b25');bg.alpha_composite(source);aa.append(np.asarray(bg.convert('RGB')).astype(float))
   seam=float(np.abs(aa[0]-aa[1]).mean())
   reports.append({'id':item['id'],'frames':im.n_frames,'duration_ms':duration,'edge_alpha_max':edge,'loop_mean_difference_0_255':round(seam,3)})
   d.text((8,row*100+39),item['id'],fill='#30382a')
   for col,ms in enumerate([0,1000,2000,3000,4200,5400]):
    ix=max(i for i,(ts,_) in enumerate(frames) if ts<=ms);fr=frames[ix][1];bg=Image.new('RGBA',(512,512),'#252b25' if col%2 else '#f4f3ea');bg.alpha_composite(fr);bg=bg.resize((100,100));sheet.paste(bg.convert('RGB'),(180+col*150,row*100))
  sheet.save(out/(kind+'-phases-'+str(start//12+1)+'.jpg'),quality=90)
(r/'collection-validation.json').write_text(json.dumps(reports,indent=2),encoding='utf-8')
print(json.dumps({'checked':len(reports),'duration_errors':[x for x in reports if x['duration_ms']!=6000],'edge_errors':[x for x in reports if x['edge_alpha_max']>4]},indent=2))
