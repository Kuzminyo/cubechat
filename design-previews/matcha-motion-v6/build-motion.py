from pathlib import Path
import sys,json,shutil,math
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import cv2,numpy as np
from PIL import Image,ImageOps,ImageFilter
ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent/'matcha-motion-v5'
SOURCE=Path('C:/Users/kuzme/.codex/generated_images/01a07721-3949-7910-9e64-eaae4d5bf0e0')
SIZE=512;N=150;MS=40
for folder in ['poses','sources','masters','png-2k','webm-2k']:(ROOT/folder).mkdir(exist_ok=True)
SHEETS={'cat-1':'exec-ec54c912-9602-449b-bb01-353a01d35fdd.png','cat-2':'exec-b023d97b-a65f-4a5f-816b-e6f3bdacd403.png','cat-3':'exec-eea3cffa-e551-4b1e-adcd-bc55f2426da0.png','cat-4':'exec-d0927014-de0e-466e-aef1-372b568176fe.png','emoji-1':'exec-44d39ee0-2a8d-4945-af1c-c80e3e9bfeb4.png','emoji-2':'exec-7562a853-d85f-4bc0-910f-9dd9fdd5a61e.png','emoji-3':'exec-af67c282-5a2f-4de3-bc8e-12616dde8b73.png','emoji-4':'exec-e3f69f53-9d96-4406-9b06-7d242fc28b90.png'}
OLD=[('cat','exec-ab3a9cf2-1f92-4ef3-8417-5bd037c923d7.png',['wave','laugh','love','sleep']),('cat','exec-6eceb6c5-6784-4154-b536-ba6d2dde23d4.png',['approve','shy','sad','angry']),('cat','exec-b60d3c56-d068-40db-acef-41819aa58ce7.png',['party','surprise','matcha','cool']),('emoji','exec-70fd9051-f89c-4732-aca7-c63ec5948460.png',['smile','laugh','heart','kiss']),('emoji','exec-8a08e3d2-dc37-483a-b1d6-32982251ef1d.png',['love','surprise','sad','angry']),('emoji','exec-ca61f2e1-c74c-4ae4-9c12-ed0c683c3976.png',['approve','clap','fire','party'])]
cv2.setNumThreads(2)
def remove_background(im,checker=False):
 rgb=np.array(im.convert('RGB')).astype(np.float32)
 if checker:
  mask=((rgb.max(2)-rgb.min(2)>16)|(rgb.min(2)<180)).astype(np.uint8)*255
  mask=cv2.morphologyEx(mask,cv2.MORPH_CLOSE,np.ones((3,3),np.uint8))
  contours,_=cv2.findContours(mask,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
  filled=np.zeros(mask.shape,np.uint8)
  for contour in contours:
   if cv2.contourArea(contour)>8:cv2.drawContours(filled,[contour],-1,255,-1)
  outline=cv2.dilate(filled,np.ones((5,5),np.uint8))
  result=np.zeros((*filled.shape,4),np.uint8);result[:,:,:3]=255
  result[filled>0,:3]=rgb[filled>0].astype(np.uint8);result[:,:,3]=outline
  return Image.fromarray(result)
 if im.mode=='RGBA' and im.getchannel('A').getextrema()[0]==0:return im
 diff=np.minimum(rgb[:,:,0],rgb[:,:,2])-rgb[:,:,1]
 bg=((diff>65)&(rgb[:,:,0]>100)&(rgb[:,:,2]>100)).astype(np.uint8)
 border=cv2.dilate(bg,np.ones((5,5),np.uint8))>0
 a=np.ones(diff.shape,np.float32)
 a[border]=np.clip(1-diff[border]/90,0,1)
 a[bg>0]=0
 key=np.array([255,0,255],np.float32)
 out=np.clip((rgb-(1-a[:,:,None])*key)/np.maximum(a[:,:,None],.001),0,255)
 return Image.fromarray(np.dstack((out.astype(np.uint8),np.uint8(a*255))))
def split(sheet,rows,checker=False):
 sheet=remove_background(sheet,checker);w,h=sheet.size;a=np.array(sheet.getchannel('A'))
 boundaries=[0]
 for q in range(1,rows):
  guess=round(h*q/rows);radius=round(h/rows*.20)
  boundaries.append(min(range(guess-radius,guess+radius+1),key=lambda y:np.count_nonzero(a[y]>128)))
 boundaries.append(h);result=[]
 for row in range(rows):
  poses=[]
  for col in range(4):
   cell=sheet.crop((round(col*w/4),boundaries[row],round((col+1)*w/4),boundaries[row+1]))
   # Remove tiny disconnected fragments from a neighboring cell without losing expression accents.
   ar=np.array(cell);count,labs,stats,_=cv2.connectedComponentsWithStats(np.uint8(ar[:,:,3]>40),8)
   for i in range(1,count):
    if stats[i,cv2.CC_STAT_AREA]<5:ar[labs==i,3]=0
   poses.append(Image.fromarray(ar))
  result.append(poses)
 return result

def normalize(poses,stem):
 boxes=[im.getchannel('A').point(lambda a:255 if a>80 else 0).getbbox() for im in poses]
 # Preserve differences such as a rising head: one shared scale for each complete action.
 widths=[b[2]-b[0] for b in boxes];heights=[b[3]-b[1] for b in boxes]
 scale=min(438/max(widths),438/max(heights))
 output=[]
 for im,b in zip(poses,boxes):
  crop=im.crop(b);res=crop.resize((round(crop.width*scale),round(crop.height*scale)),Image.Resampling.LANCZOS)
  canvas=Image.new('RGBA',(SIZE,SIZE));left=(SIZE-res.width)//2
  top=(SIZE-res.height)//2 if stem.startswith('emoji-') else 475-res.height
  canvas.alpha_composite(res,(left,top));output.append(canvas)
 return output

def prepare():
 all_poses={}
 for kind,filename,names in OLD:
  path=SOURCE/filename;shutil.copy2(path,ROOT/'sources'/filename)
  for name,poses in zip(names,split(Image.open(path),4)):all_poses[kind+'-'+name]=normalize(poses,kind+'-'+name)
 batches=json.loads((ROOT/'batches.json').read_text(encoding='utf-8'))
 for batch in batches:
  filename=SHEETS[batch['name']];shutil.copy2(SOURCE/filename,ROOT/'sources'/filename)
  rows=split(Image.open(SOURCE/filename),6,batch['name']=='cat-1')
  for item,poses in zip(batch['items'],rows):
   stem=item['id']
   # Reject the generated first flower frame: it incorrectly contains a trophy.
   if stem=='cat-flower':poses=[poses[1],poses[2],poses[3],poses[1]]
   # Keep sweat on the original side; the third generated drawing moves it across the face.
   if stem=='emoji-sweat':poses=[poses[0],poses[1],poses[1],poses[3]]
   all_poses[stem]=normalize(poses,stem)
 for stem,poses in all_poses.items():
  for i,im in enumerate(poses):im.save(ROOT/'poses'/(stem+'-'+str(i)+'.png'))
  # The approved still is unchanged; the new files add movement phases only.
  shutil.copy2(BASE/(stem+'.png'),ROOT/(stem+'.png'))
  shutil.copy2(BASE/'masters'/(stem+'.png'),ROOT/'masters'/(stem+'.png'))
  shutil.copy2(BASE/'png-2k'/(stem+'.png'),ROOT/'png-2k'/(stem+'.png'))
 manifest=json.loads((BASE/'manifest.json').read_text(encoding='utf-8'))
 for item in manifest:
  item.update({'cycle_ms':6000,'fps':25,'size_webp':[512,512],'source_poses':4,'sampled_frames':150,'motion_revision':'06','method':'four drawn action poses, registered to shared anchor; single-source optical-flow inbetweens with eased timing and expression holds'})
 (ROOT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
 return all_poses

yy,xx=np.mgrid[0:SIZE,0:SIZE].astype(np.float32);grid=np.stack((xx,yy),axis=-1)
def premult(im):
 a=np.array(im).astype(np.float32)/255;a[:,:,:3]*=a[:,:,3:4];return a

def to_image(a):
 out=a.copy();out[:,:,:3]=np.divide(a[:,:,:3],a[:,:,3:4],out=np.zeros_like(a[:,:,:3]),where=a[:,:,3:4]>.002)
 return Image.fromarray(np.uint8(np.clip(out,0,1)*255))

def flow_gray(a):
 rgb=a[:,:,:3]+(1-a[:,:,3:4])*np.array([.96,.95,.92],np.float32)
 return cv2.cvtColor(np.uint8(np.clip(rgb,0,1)*255),cv2.COLOR_RGB2GRAY)

def flow(a,b):
 dis=cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM);dis.setVariationalRefinementIterations(15)
 return dis.calc(flow_gray(a),flow_gray(b),None)

def warp(a,f,t):
 m=grid-t*f
 for _ in range(2):m=grid-t*cv2.remap(f,m[:,:,0],m[:,:,1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
 return cv2.remap(a,m[:,:,0],m[:,:,1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)

def smooth(t):return t*t*(3-2*t)

def render(poses):
 arrays=[premult(im) for im in poses]
 links={}
 for i in range(4):
  j=(i+1)%4;links[i]=(flow(arrays[i],arrays[j]),flow(arrays[j],arrays[i]))
 frames=[]
 # 1.2s hold on the initial pose, 0.4s preparation, 0.8s action hold,
 # 0.56s transition, 1.04s expressive hold, 0.56s release, 0.84s hold, 0.6s return.
 spans=[(0,30,0,0),(30,40,0,1),(40,60,1,1),(60,74,1,2),(74,100,2,2),(100,114,2,3),(114,135,3,3),(135,150,3,0)]
 for start,end,i,j in spans:
  for fi in range(start,end):
   if i==j:frames.append(poses[i]);continue
   t=smooth((fi-start+1)/(end-start+1));fa,fb=links[i]
   # Use one drawing at a time: interpolating opacity gives doubled eyes and ghost paws.
   a=warp(arrays[i],fa,t) if t<.5 else warp(arrays[j],fb,1-t)
   frames.append(to_image(a))
 return frames

def save(stem,poses):
 frames=render(poses)
 frames[0].save(ROOT/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=MS,loop=0,quality=94,method=2,alpha_quality=100)
 rgb=[]
 for im in frames:
  bg=Image.new('RGBA',im.size,'#f4f3ea');bg.alpha_composite(im);rgb.append(bg.resize((240,240),Image.Resampling.LANCZOS).convert('RGB'))
 strip=Image.new('RGB',(240*6,240))
 for i,f in enumerate([0,35,55,70,95,125]):strip.paste(rgb[f],(240*i,0))
 palette=strip.quantize(colors=256,method=Image.Quantize.MEDIANCUT)
 gif=[im.quantize(palette=palette,dither=Image.Dither.NONE) for im in rgb]
 gif[0].save(ROOT/(stem+'.gif'),save_all=True,append_images=gif[1:],duration=MS,loop=0,disposal=1,optimize=True)
 if stem in ['cat-wave','cat-thanks','cat-peek','emoji-wink','emoji-shush']:
  strip.save(ROOT/(stem+'-motion-check.jpg'),quality=94)
 print(stem+' action loop ready',flush=True)
 return stem

if __name__=='__main__':
 from concurrent.futures import ThreadPoolExecutor,as_completed
 all_poses=prepare()
 if '--prepare-only' in sys.argv:print('72 actions / 288 poses prepared');sys.exit(0)
 selected={s:p for s,p in all_poses.items() if (not (ROOT/(s+'.webp')).exists()) or ('--rekey' in sys.argv and s not in {kind+'-'+name for kind,_,names in OLD for name in names} and s not in ['cat-thanks','cat-thinking','cat-facepalm','cat-hug','cat-tired','cat-waiting'])} if '--sample' not in sys.argv else {x:all_poses[x] for x in ['cat-wave','cat-thanks','cat-peek','emoji-wink','emoji-shush']}
 with ThreadPoolExecutor(max_workers=3) as pool:
  for f in as_completed([pool.submit(save,stem,poses) for stem,poses in selected.items()]):f.result()
 print(str(len(selected))+' action animations ready',flush=True)
