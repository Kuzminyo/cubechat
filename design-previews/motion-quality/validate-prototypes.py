from pathlib import Path
from PIL import Image
import numpy as np,json
r=Path('D:/projects/cubechat/design-previews/motion-quality');results=[]
for stem in ['cat-morning','cat-laugh','cat-flower','cat-victory']:
 with Image.open(r/(stem+'-rig.webp')) as im:
  total=0;first=None;last=None;bounds=[]
  for fi in range(im.n_frames):
   im.seek(fi);im.load();total+=im.info.get('duration',0);rgba=im.convert('RGBA');a=np.array(rgba)
   assert rgba.size==(512,512)
   assert a[0,:,3].max()==a[-1,:,3].max()==a[:,0,3].max()==a[:,-1,3].max()==0,(stem,fi,'clipped')
   visible=a[:,:,:3].astype(float)*a[:,:,3:4]/255
   if first is None:first=visible
   last=visible;bounds.append(rgba.getchannel('A').getbbox())
  assert total==6000,(stem,total)
  assert im.n_frames>=120,(stem,im.n_frames)
  seam=float(np.abs(first-last).mean());assert seam<2.0,(stem,seam)
  results.append({'id':stem,'frames':im.n_frames,'cycle_ms':total,'transparent_borders':True,'loop_seam_mean_0_255':round(seam,4),'bytes':(r/(stem+'-rig.webp')).stat().st_size})
report={'scope':'four working prototypes only; full 72-item goal not complete','checks':results,'visual_review':'key poses inspected; character fidelity and full motion review still in progress'}
(r/'prototype-validation.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report,indent=2))
