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

def smooth_motion(stem,im):
 a=rgba_array(im)
 mask=np.uint8(np.asarray(im.getchannel('A'))>180)
 count,components,stats,centers=cv2.connectedComponentsWithStats(mask,8)
 largest=1+int(np.argmax(stats[1:,cv2.CC_STAT_AREA]))
 x,y,w,h=stats[largest,:4].astype(float)
 cx=x+w*.5;cy=y+h*.55
 def point(px,py):return x+w*px,y+h*py
 def field(m,px,py,dx,dy,rx,ry):
  weight=np.exp(-.5*(((xx-px)/rx)**2+((yy-py)/ry)**2))
  m[:,:,0]-=dx*weight;m[:,:,1]-=dy*weight
 def rotate(m,px,py,angle,rx,ry):
  vx=xx-px;vy=yy-py
  weight=np.exp(-.5*((vx/rx)**2+(vy/ry)**2))
  co=math.cos(angle);si=math.sin(angle)
  m[:,:,0]+=((co-1)*vx+si*vy)*weight
  m[:,:,1]+=(-si*vx+(co-1)*vy)*weight
 def pulse(m,px,py,amount,rx,ry):
  weight=np.exp(-.5*(((xx-px)/rx)**2+((yy-py)/ry)**2))
  m[:,:,0]-=(xx-px)*amount*weight
  m[:,:,1]-=(yy-py)*amount*weight
 output=[]
 for fi in range(N):
  phase=fi/N;v=math.sin(2*math.pi*phase);u=(1-math.cos(2*math.pi*phase))/2
  m=grid.copy()
  if stem=='emoji-heart':
   beat=.09*math.exp(-((phase-.28)/.09)**2)+.055*math.exp(-((phase-.49)/.075)**2)
   m[:,:,0]=cx+(xx-cx)/(1+beat);m[:,:,1]=cy+(yy-cy)/(1+beat)
  elif stem=='emoji-fire':
   # Keep the flame base planted while the tip sways continuously.
   rise=np.clip((y+h-yy)/h,0,1)
   m[:,:,0]-=9*rise**1.7*np.sin(2*math.pi*phase+rise*2.0)
   m[:,:,1]-=3*rise*u
  elif stem.startswith('cat-'):
   headx,heady=point(.48,.32)
   pulse(m,*point(.5,.71),.015*u,w*.40,h*.32)
   # A small tail sway maintains a living idle pose without shifting the feet.
   field(m,*point(.85,.65),3.5*v,-1.5*u,w*.14,h*.25)
   if stem=='cat-wave':
    field(m,*point(.20,.54),4*v,-12*u,w*.15,h*.16)
    rotate(m,headx,heady,.018*v,w*.45,h*.35)
   elif stem=='cat-laugh':
    field(m,headx,heady,1.5*v,-5*u,w*.43,h*.35)
    rotate(m,headx,heady,.028*v,w*.43,h*.32)
   elif stem=='cat-love':
    pulse(m,*point(.49,.66),.07*u,w*.25,h*.22)
    rotate(m,headx,heady,.016*v,w*.40,h*.30)
   elif stem=='cat-sleep':
    pulse(m,*point(.63,.44),.022*u,w*.36,h*.30)
    field(m,*point(.82,.38),2*v,-3*u,w*.15,h*.26)
   elif stem=='cat-approve':
    field(m,*point(.26,.60),1*v,-7*u,w*.17,h*.19)
    field(m,headx,heady,0,2.5*u,w*.43,h*.30)
   elif stem=='cat-shy':
    rotate(m,headx,heady,.018*v,w*.44,h*.34)
    field(m,*point(.25,.65),2*u,-2*u,w*.14,h*.16)
    field(m,*point(.72,.65),-2*u,-2*u,w*.14,h*.16)
   elif stem=='cat-sad':
    field(m,headx,heady,0,3*u,w*.43,h*.35)
    rotate(m,headx,heady,.01*v,w*.40,h*.32)
   elif stem=='cat-angry':
    pulse(m,headx,heady,.017*u,w*.4,h*.28)
    field(m,*point(.5,.06),2*v,-4*u,w*.25,h*.13)
   elif stem=='cat-party':
    rotate(m,*point(.5,.56),.035*v,w*.65,h*.60)
    field(m,*point(.18,.52),-2*v,-5*u,w*.2,h*.22)
    field(m,*point(.78,.48),2*v,-5*u,w*.2,h*.22)
   elif stem=='cat-surprise':
    field(m,headx,heady,0,-4*u,w*.43,h*.35)
    pulse(m,headx,heady,.018*u,w*.45,h*.35)
   elif stem=='cat-matcha':
    field(m,*point(.51,.63),0,-6*u,w*.27,h*.23)
    rotate(m,headx,heady,.012*v,w*.43,h*.34)
   elif stem=='cat-cool':
    rotate(m,headx,heady,.025*v,w*.44,h*.35)
    field(m,*point(.19,.5),0,-4*u,w*.16,h*.2)
  elif stem=='emoji-clap':
   rotate(m,cx,cy,.018*v,w*.7,h*.7)
   field(m,*point(.26,.55),4*u,-1*u,w*.24,h*.4)
   field(m,*point(.72,.48),-4*u,1*u,w*.24,h*.4)
  elif stem=='emoji-approve':
   rotate(m,*point(.5,.8),.04*v,w*.7,h*.8)
   field(m,*point(.48,.18),1*v,-2*u,w*.25,h*.35)
  elif stem=='emoji-party':
   rotate(m,cx,cy,.03*v,w*.7,h*.7)
   field(m,*point(.12,.62),-5*u,0,w*.20,h*.18)
  else:
   rotate(m,cx,cy,.02*v,w*.65,h*.65)
   pulse(m,cx,cy,.012*u,w*.5,h*.5)
   if stem=='emoji-love':
    pulse(m,*point(.32,.39),.07*u,w*.18,h*.17)
    pulse(m,*point(.68,.39),.07*u,w*.18,h*.17)
   elif stem=='emoji-laugh':
    field(m,*point(.5,.65),0,-3*u,w*.34,h*.28)
    field(m,*point(.16,.6),0,3*u,w*.12,h*.2)
    field(m,*point(.84,.6),0,3*u,w*.12,h*.2)
   elif stem=='emoji-kiss':
    pulse(m,*point(.75,.58),.075*u,w*.17,h*.18)
   elif stem=='emoji-surprise':
    pulse(m,*point(.5,.67),.06*u,w*.17,h*.22)
   elif stem=='emoji-angry':
    field(m,*point(.34,.35),0,2*u,w*.2,h*.17)
    field(m,*point(.66,.35),0,2*u,w*.2,h*.17)
   elif stem=='emoji-sad':
    field(m,*point(.19,.61),0,4*u,w*.12,h*.22)
  output.append(straight_image(remap(a,m)))
 return output

CACHED={'cat-wave','cat-laugh','cat-love','cat-sleep','cat-approve','cat-shy','cat-sad','cat-angry','cat-party','cat-surprise','cat-matcha','cat-cool','emoji-smile'}
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
  chosen={'cat-wave':1,'cat-shy':2,'cat-matcha':2,'cat-cool':1,'emoji-kiss':1}.get(stem,0)
  if stem in CACHED:
   frames=[]
   with Image.open(ROOT/(stem+'.webp')) as cached:
    for k in range(cached.n_frames):
     cached.seek(k);cached.load()
     frames.extend([cached.convert('RGBA').copy()]*max(1,round(cached.info.get('duration',MS)/MS)))
   assert len(frames)==N,(stem,len(frames))
  else:
   frames=smooth_motion(stem,keyframes[chosen])
  if stem not in CACHED:
   frames[0].save(ROOT/(stem+'.png'))
   frames[0].save(ROOT/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=MS,loop=0,quality=92,method=2,minimize_size=False)
   gifframes=[]
   for frame in frames:
    bg=Image.new('RGBA',(SIZE,SIZE),'#f4f3ea');bg.alpha_composite(frame)
    gifframes.append(bg.resize((240,240),Image.Resampling.LANCZOS).convert('RGB'))
   gifframes[0].save(ROOT/(stem+'.gif'),save_all=True,append_images=gifframes[1:],duration=MS,loop=0,disposal=2,optimize=False)
  index=len(manifest)
  for fi,frame in enumerate(frames):
   preview[fi].alpha_composite(frame.resize((132,132),Image.Resampling.LANCZOS),((index%6)*140+4,(index//6)*140+4))
  manifest.append({'id':stem,'label':labels[row],'kind':kind,'size_webp':[SIZE,SIZE],'size_gif':[240,240],'cycle_ms':N*MS,'source_poses':1,'sampled_frames':N,'fps':25,'method':'continuous local mesh animation of the approved artwork; periodic eased motion, no crossfading between mismatched poses'})
  if stem=='cat-wave':
   montage=Image.new('RGB',(SIZE*5,SIZE*2),'#f4f3ea')
   for j,k in enumerate([0,5,10,15,20,25,30,35,40,45]):
    tile=Image.new('RGBA',(SIZE,SIZE),'#f4f3ea');tile.alpha_composite(frames[k]);montage.paste(tile.convert('RGB'),((j%5)*SIZE,(j//5)*SIZE))
   montage.save(ROOT/'motion-check.png')
  print(stem+' ready ('+str(index+1)+'/24)',flush=True)
preview_rgb=[im.convert('RGB') for im in preview]
preview_rgb[0].save(ROOT/'animated-preview.gif',save_all=True,append_images=preview_rgb[1:],duration=MS,loop=0,disposal=2,optimize=False)
preview_rgb[0].save(ROOT/'preview-still.png')
preview_rgb[0].save(ROOT/'animated-preview.webp',save_all=True,append_images=preview_rgb[1:],duration=MS,loop=0,quality=88,method=2)
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

