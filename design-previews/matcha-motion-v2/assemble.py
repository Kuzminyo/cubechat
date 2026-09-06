from pathlib import Path
import sys, json, shutil, zipfile, math, time
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import cv2
import numpy as np
from PIL import Image, ImageOps
ROOT=Path(__file__).resolve().parent
SOURCE=Path('C:/Users/kuzme/.codex/generated_images/01a07721-3949-7910-9e64-eaae4d5bf0e0')
N=100; SIZE=320; MS=40
SPECS=[
 ('cat','exec-ab3a9cf2-1f92-4ef3-8417-5bd037c923d7.png',['wave','laugh','love','sleep'],['Привет','Смех','Любовь','Сон']),
 ('cat','exec-6eceb6c5-6784-4154-b536-ba6d2dde23d4.png',['approve','shy','sad','angry'],['Одобряю','Смущение','Грусть','Сержусь']),
 ('cat','exec-b60d3c56-d068-40db-acef-41819aa58ce7.png',['party','surprise','matcha','cool'],['Праздник','Удивление','Перерыв с матчей','Всё под контролем']),
 ('emoji','exec-70fd9051-f89c-4732-aca7-c63ec5948460.png',['smile','laugh','heart','kiss'],['Улыбка','Смех','Сердце','Поцелуй']),
 ('emoji','exec-8a08e3d2-dc37-483a-b1d6-32982251ef1d.png',['love','surprise','sad','angry'],['Влюблённость','Удивление','Грусть','Злость']),
 ('emoji','exec-ca61f2e1-c74c-4ae4-9c12-ed0c683c3976.png',['approve','clap','fire','party'],['Лайк','Аплодисменты','Огонь','Праздник'])]
cv2.setNumThreads(4)
yy,xx=np.mgrid[0:SIZE,0:SIZE].astype(np.float32)
grid=np.stack((xx,yy),axis=-1)
def rgba_array(im):
 a=np.asarray(im,dtype=np.float32)/255
 a[:,:,:3]*=a[:,:,3:4]
 return a
def straight_image(a):
 b=a.copy()
 b[:,:,:3]=np.divide(a[:,:,:3],a[:,:,3:4],out=np.zeros_like(a[:,:,:3]),where=a[:,:,3:4]>.002)
 return Image.fromarray(np.uint8(np.clip(b,0,1)*255))
def gray(a):
 rgb=a[:,:,:3]+(1-a[:,:,3:4])*np.array([.957,.953,.918],np.float32)
 return cv2.cvtColor(np.uint8(np.clip(rgb,0,1)*255),cv2.COLOR_RGB2GRAY)
def flow_pair(a,b):
 dis=cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
 dis.setVariationalRefinementIterations(12)
 fa=dis.calc(gray(a),gray(b),None)
 fb=dis.calc(gray(b),gray(a),None)
 return fa,fb
def remap(a,m):
 return cv2.remap(a,m[:,:,0],m[:,:,1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT,borderValue=0)
def inverse_map(flow,t):
 m=grid-t*flow
 # Invert the forward displacement field to avoid drifting silhouettes.
 for _ in range(3):
  m=grid-t*cv2.remap(flow,m[:,:,0],m[:,:,1],cv2.INTER_LINEAR,borderMode=cv2.BORDER_REPLICATE)
 return m
def between(a,b,fa,fb,t):
 if t<.00001:return straight_image(a)
 if t>.99999:return straight_image(b)
 return straight_image(remap(a,inverse_map(fa,t))*(1-t)+remap(b,inverse_map(fb,1-t))*t)
def extract(sheet):
 w,h=sheet.size
 alpha=np.asarray(sheet.getchannel('A'))
 rows=[0]
 for q in range(1,4):
  e=round(h*q/4)
  rows.append(min(range(e-24,e+25),key=lambda y:np.count_nonzero(alpha[y]>200)))
 rows.append(h)
 result=[]
 for row in range(4):
  frames=[]
  cols=[0]
  for q in range(1,4):
   e=round(w*q/4)
   cols.append(min(range(e-14,e+15),key=lambda x:np.count_nonzero(alpha[rows[row]:rows[row+1],x]>200)))
  cols.append(w)
  for col in range(4):
   im=sheet.crop((cols[col],rows[row],cols[col+1],rows[row+1]))
   frames.append(ImageOps.pad(im,(SIZE,SIZE),method=Image.Resampling.LANCZOS,color=(0,0,0,0)))
  result.append(frames)
 return result
manifest=[]
preview=[Image.new('RGBA',(840,560),'#f4f3ea') for _ in range(N)]
comparison=None
start=time.time()
for kind,filename,names,labels in SPECS:
 sheet=Image.open(SOURCE/filename).convert('RGBA')
 shutil.copy2(SOURCE/filename,ROOT/filename)
 for row,keyframes in enumerate(extract(sheet)):
  stem=kind+'-'+names[row]
  # The generated approval frame changes paw sides; exclude that frame from motion.
  if stem=='cat-approve': keyframes=[keyframes[i] for i in [0,2,3,0]]
  # Keep the tear on the same cheek for the sad cat.
  if stem=='cat-sad': keyframes=[keyframes[i] for i in [3,1,2,3]]
  arrays=[rgba_array(im) for im in keyframes]
  pairs=[flow_pair(arrays[i],arrays[(i+1)%4]) for i in range(4)]
  frames=[]
  for fi in range(N):
   phase=fi/N*4
   pair=int(phase)%4; local=phase-int(phase)
   # Rest gently at each pose, easing in and out of every transition.
   t=max(0,min(1,(local-.16)/.76))
   t=t*t*(3-2*t)
   fa,fb=pairs[pair]
   frames.append(between(arrays[pair],arrays[(pair+1)%4],fa,fb,t))
  frames[0].save(ROOT/(stem+'.png'))
  frames[0].save(ROOT/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=MS,loop=0,quality=92,method=4,minimize_size=True)
  gifframes=[]
  for frame in frames:
   bg=Image.new('RGBA',(SIZE,SIZE),'#f4f3ea');bg.alpha_composite(frame)
   gifframes.append(bg.resize((240,240),Image.Resampling.LANCZOS).convert('RGB'))
  gifframes[0].save(ROOT/(stem+'.gif'),save_all=True,append_images=gifframes[1:],duration=MS,loop=0,disposal=2,optimize=False)
  index=len(manifest)
  for fi,frame in enumerate(frames):
   preview[fi].alpha_composite(frame.resize((132,132),Image.Resampling.LANCZOS),((index%6)*140+4,(index//6)*140+4))
  manifest.append({'id':stem,'label':labels[row],'kind':kind,'size_webp':[SIZE,SIZE],'size_gif':[240,240],'cycle_ms':N*MS,'source_keyframes':4,'sampled_frames':N,'fps':25,'method':'bidirectional optical-flow interpolation with smoothstep easing and short pose holds'})
  if stem=='cat-wave':
   montage=Image.new('RGB',(SIZE*5,SIZE*2),'#f4f3ea')
   for j,k in enumerate([0,5,10,15,20,25,30,35,40,45]):
    tile=Image.new('RGBA',(SIZE,SIZE),'#f4f3ea');tile.alpha_composite(frames[k]);montage.paste(tile.convert('RGB'),((j%5)*SIZE,(j//5)*SIZE))
   montage.save(ROOT/'motion-check.png')
  print(stem+' ready ('+str(index+1)+'/24)',flush=True)
preview_rgb=[im.convert('RGB') for im in preview]
preview_rgb[0].save(ROOT/'animated-preview.gif',save_all=True,append_images=preview_rgb[1:],duration=MS,loop=0,disposal=2,optimize=False)
preview_rgb[0].save(ROOT/'preview-still.png')
preview_rgb[0].save(ROOT/'animated-preview.webp',save_all=True,append_images=preview_rgb[1:],duration=MS,loop=0,quality=88,method=4)
(ROOT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
# Decode every exported frame, verify timings and record actual encoder frame counts.
checks=[]
for item in manifest:
 for suffix in ['.webp','.gif']:
  path=ROOT/(item['id']+suffix)
  with Image.open(path) as check:
   assert check.is_animated,path
   total=0
   for f in range(check.n_frames):
    check.seek(f);check.load();total+=check.info.get('duration',0)
   assert total==4000,(path,total)
   assert check.n_frames>=50,(path,check.n_frames)
   checks.append({'file':path.name,'frames':check.n_frames,'duration_ms':total,'bytes':path.stat().st_size})
(ROOT/'validation.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
print(json.dumps({'verified_files':len(checks),'seconds':round(time.time()-start),'output':str(ROOT)},indent=2),flush=True)

