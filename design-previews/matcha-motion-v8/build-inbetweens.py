from pathlib import Path
import sys,json,hashlib
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import cv2,numpy as np
from PIL import Image,ImageDraw
ROOT=Path(__file__).resolve().parent

def key(im):
 if im.mode=='RGBA' and im.getchannel('A').getextrema()[0]==0:return im
 rgb=np.array(im.convert('RGB')).astype(float);d=np.minimum(rgb[:,:,0],rgb[:,:,2])-rgb[:,:,1];bg=(d>65)&(rgb[:,:,0]>100)&(rgb[:,:,2]>100)
 edge=cv2.dilate(bg.astype('uint8'),np.ones((5,5),np.uint8))>0;a=np.ones(d.shape);a[edge]=np.clip(1-d[edge]/90,0,1);a[bg]=0
 rgb=np.clip((rgb-(1-a[:,:,None])*[255,0,255])/np.maximum(a[:,:,None],.001),0,255)
 pixels=np.dstack((rgb.astype('uint8'),np.uint8(a*255)));n,labels,stats,_=cv2.connectedComponentsWithStats(np.uint8(a>.2),8)
 for i in range(1,n):
  x,y,ww,hh,area=stats[i];largest=stats[1:,cv2.CC_STAT_AREA].max()
  touches_edge=x<=2 or y<=2 or x+ww>=im.width-2 or y+hh>=im.height-2
  if area<max(8,largest*.0008) or (touches_edge and area<largest*.2):pixels[labels==i,3]=0
 return Image.fromarray(pixels)
def bbox(im):return im.getchannel('A').point(lambda x:255 if x>80 else 0).getbbox()
def build(stem,path):
 original=[Image.open(ROOT/'original-poses'/(stem+'-'+str(i)+'.png')).convert('RGBA') for i in range(4)]
 sheet=Image.open(ROOT/path);w,h=sheet.size;frames=[];drawings=[]
 # Original key poses are kept intact. New drawings only receive a whole-image
 # uniform scale/translation to match the neighboring originals' framing.
 for row in range(4):
  drawings.append(original[row]);frames.extend([original[row]]*([23,22,23,22][row]))
  ba=np.array(bbox(original[row]),float);bb=np.array(bbox(original[(row+1)%4]),float)
  for col in range(3):
   idx=({'cat-wave':[0,11,1,2,3,4,5,7,9,9,10,11],'cat-laugh':[0,1,2,4,5,6,6,7,8,9,10,11],'cat-shy':[0,1,1,2,3,4,6,7,8,9,10,11]}.get(stem,list(range(12))))[row*3+col];sy,sx=divmod(idx,3)
   im=key(sheet.crop((round(sx*w/3),round(sy*h/4),round((sx+1)*w/3),round((sy+1)*h/4))));im=im.crop(bbox(im));t=(col+1)/4;target=ba*(1-t)+bb*t
   scale=min((target[2]-target[0])/im.width,(target[3]-target[1])/im.height);im=im.resize((round(im.width*scale),round(im.height*scale)),Image.Resampling.LANCZOS)
   canvas=Image.new('RGBA',(512,512));x=round((target[0]+target[2]-im.width)/2);y=round(target[3]-im.height);canvas.alpha_composite(im,(x,y));canvas.save(ROOT/'inbetweens'/(stem+'-'+str(row)+'-'+str(col)+'.png'));drawings.append(canvas);frames.extend([canvas]*5)
 assert len(frames)==150
 frames[0].save(ROOT/(stem+'.png'));frames[0].save(ROOT/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=40,loop=0,quality=96,method=2,alpha_quality=100)
 contact=Image.new('RGB',(1000,1000),'#f4f3ea');d=ImageDraw.Draw(contact)
 for i,im in enumerate(drawings):
  bg=Image.new('RGBA',(512,512),'#f4f3ea' if i%2==0 else '#20251f');bg.alpha_composite(im);contact.paste(bg.resize((235,235)).convert('RGB'),(i%4*250,i//4*250));d.text((i%4*250+6,i//4*250+235),'ORIGINAL' if i%4==0 else 'inbetween '+str(i%4),fill='#6b745d')
 contact.save(ROOT/(stem+'-contact.jpg'),quality=90)
 items=json.loads((ROOT/'manifest.json').read_text(encoding='utf-8'))
 for item in items:
  if item['id']==stem:item.update({'revision_status':'inbetweens_added','drawn_frames':16,'original_frames_unchanged':4,'new_inbetweens':len(set({'cat-wave':[0,11,1,2,3,4,5,7,9,9,10,11],'cat-laugh':[0,1,2,4,5,6,6,7,8,9,10,11],'cat-shy':[0,1,1,2,3,4,6,7,8,9,10,11]}.get(stem,list(range(12))))),'duration_ms':6000,'method':'original key poses plus new drawn intermediate frames; no optical flow or layer rig'})
 (ROOT/'manifest.json').write_text(json.dumps(items,ensure_ascii=False,indent=2),encoding='utf-8')
 print(stem+': 4 unchanged original poses + 12 inbetweens, 6 second loop',flush=True)
if __name__=='__main__':
 batches=json.loads((ROOT/'batches.json').read_text(encoding='utf-8'))
 for stem,path in batches.items():
  if len(sys.argv)<2 or stem in sys.argv[1:]:build(stem,path)
