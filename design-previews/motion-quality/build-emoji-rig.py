from pathlib import Path
import sys,math,json,shutil
from functools import lru_cache
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFilter,ImageOps
ROOT=Path(__file__).resolve().parent;OUT=ROOT/'emoji-rig';OUT.mkdir(exist_ok=True)
PARTS=ROOT/'emoji-parts';PARTS.mkdir(exist_ok=True)
SOURCE=Path('C:/Users/kuzme/.codex/generated_images/01a07721-3949-7910-9e64-eaae4d5bf0e0')
SOURCES={'base':'exec-b337b156-b5cd-4a6b-a80a-b1f5aa197d4c.png','features':'exec-8d9b261d-dbdb-4255-a7ac-81ca2cbf7688.png','props':'exec-340110d9-4f0a-445b-99e4-9c32f9381c24.png'}
for kind,filename in SOURCES.items():
 if not (ROOT/('emoji-source-'+kind+'.png')).exists():shutil.copy2(SOURCE/filename,ROOT/('emoji-source-'+kind+'.png'))
SIZE=512;N=150;MS=40

def key(im):
 rgb=np.array(im.convert('RGB')).astype(np.float32);d=np.minimum(rgb[:,:,0],rgb[:,:,2])-rgb[:,:,1]
 bg=(d>65)&(rgb[:,:,0]>100)&(rgb[:,:,2]>100)
 edge=cv2.dilate(bg.astype(np.uint8),np.ones((5,5),np.uint8))>0
 a=np.ones(d.shape,np.float32);a[edge]=np.clip(1-d[edge]/90,0,1);a[bg]=0
 rgb=np.clip((rgb-(1-a[:,:,None])*np.array([255,0,255]))/np.maximum(a[:,:,None],.001),0,255)
 out=Image.fromarray(np.dstack((rgb.astype(np.uint8),np.uint8(a*255))))
 # Remove tiny detached marks from neighboring sprite cells before measuring anchors.
 pixels=np.array(out);count,labels,stats,_=cv2.connectedComponentsWithStats((pixels[:,:,3]>40).astype(np.uint8),8)
 if count>1:
  minimum=max(15,int(stats[1:,cv2.CC_STAT_AREA].max()*.006))
  for i in range(1,count):
   if stats[i,cv2.CC_STAT_AREA]<minimum:pixels[labels==i,3]=0
 out=Image.fromarray(pixels)
 box=out.getchannel('A').point(lambda v:255 if v>80 else 0).getbbox()
 return out.crop(box)
FEATURES=['eyes-open','eyes-happy','eyes-angry','eyes-white','eyes-pleading','smile','laugh','oh','frown','flat','kiss','grin','tongue-mouth','brows-raised','brows-worried','glasses']
PROPS=['hand-open','hand-clap','hand-shush','hand-salute','hand-think','hand-cover','hand-prayer','hand-approve','tear','heart','star','halo','zipper','hat','blower','explosion']
parts={}
parts['base']=key(Image.open(ROOT/'emoji-source-base.png'))
for kind,names in [('features',FEATURES),('props',PROPS)]:
 sheet=Image.open(ROOT/('emoji-source-'+kind+'.png'));w,h=sheet.size
 for i,name in enumerate(names):
  cell=sheet.crop((round(i%4*w/4),round(i//4*h/4),round((i%4+1)*w/4),round((i//4+1)*h/4)))
  parts[name]=key(cell)
for name in ['eyes-open','eyes-happy','eyes-angry','eyes-white','eyes-pleading','brows-raised','brows-worried']:
 im=parts[name]
 for side in [0,1]:
  p=im.crop((round(side*im.width/2),0,round((side+1)*im.width/2),im.height))
  p=p.crop(p.getchannel('A').getbbox());parts[name+('-l' if side==0 else '-r')]=p
# The tongue is a distinct colored component, never a deformed full face.
t=np.array(parts['tongue-mouth']);rgb=t[:,:,:3].astype(float);red=(rgb[:,:,0]>110)&(rgb[:,:,0]>rgb[:,:,1]*1.35)&(rgb[:,:,0]>rgb[:,:,2]*1.4)
t[:,:,3]=np.where(red,t[:,:,3],0);im=Image.fromarray(t);parts['tongue']=im.crop(im.getchannel('A').getbbox())
# Zipper pull is hinged at its top. The remaining zipper teeth stay fixed.
z=parts['zipper'];cut=round(z.width*.74);parts['zipper-body']=z.crop((0,0,cut,z.height));parts['zipper-pull']=z.crop((cut,0,z.width,z.height))
for name,im in parts.items():im.save(PARTS/(name+'.png'))
# Preserve the approved non-face drawings where no reconstruction is needed.
for name in ['heart','fire','approve']:
 im=Image.open(ROOT.parent/'matcha-motion-v6/masters'/('emoji-'+name+'.png')).convert('RGBA')
 parts['original-'+name]=im.crop(im.getchannel('A').point(lambda v:255 if v>80 else 0).getbbox())
for name in ['base']:
 im=parts[name].resize((392,392),Image.Resampling.LANCZOS)
 a=np.array(im.getchannel('A'));yy,xx=np.mgrid[:392,:392];circle=np.uint8(np.clip((195.5-np.sqrt((xx-195.5)**2+(yy-195.5)**2))*255,0,255))
 im.putalpha(Image.fromarray(np.minimum(a,circle)));parts[name]=im

@lru_cache(maxsize=1400)
def fitted(name,w,h,mirror=False,flip=False):
 im=parts[name]
 if w is None:w=round(im.width*h/im.height)
 if h is None:h=round(im.height*w/im.width)
 if mirror:im=ImageOps.mirror(im)
 if flip:im=ImageOps.flip(im)
 return im.resize((max(1,w),max(1,h)),Image.Resampling.LANCZOS)
def put(canvas,name,xy,w=None,h=None,angle=0,opacity=1,mirror=False,flip=False):
 im=fitted(name,round(w) if w else None,round(h) if h else None,mirror,flip)
 if opacity<.999:
  im=im.copy();im.putalpha(im.getchannel('A').point(lambda v:round(v*max(0,opacity))))
 if abs(angle)>.02:im=im.rotate(angle,resample=Image.Resampling.BICUBIC,expand=True)
 canvas.alpha_composite(im,(round(xy[0]-im.width/2),round(xy[1]-im.height/2)))
def ease(x):return x*x*(3-2*x)
def track(t,keys):
 for (a,va),(b,vb) in zip(keys,keys[1:]):
  if a<=t<=b:return va+(vb-va)*ease((t-a)/(b-a))
 return keys[-1][1]
def action(t):return track(t,[(0,0),(.14,0),(.36,1),(.63,1),(.91,0),(1,0)])
def pulse(t,center,width):
 x=abs(t-center)/width
 return 0 if x>=1 else .5+.5*math.cos(math.pi*x)
def blink(t):return pulse(t,.79,.028)

def oval_eye(canvas,x,y,closed=0,side='l',style='open'):
 if closed>.86:
  put(canvas,'eyes-happy-'+side,(x,y),w=48);return
 im=fitted('eyes-'+style+'-'+side,42 if style=='open' else 78,None)
 # Eyelid motion clips the pupil image; it does not rescale/distort the eyeball.
 if closed>.01:
  im=im.copy();a=np.array(im.getchannel('A'));keep=max(4,round(im.height*(1-.8*closed)));start=(im.height-keep)//2;a[:start]=0;a[start+keep:]=0;im.putalpha(Image.fromarray(a))
 canvas.alpha_composite(im,(round(x-im.width/2),round(y-im.height/2)))
def white_eye(canvas,x,y,gaze=(0,0),half=False,closed=0):
 if closed>.85:
  put(canvas,'eyes-happy-l',(x,y),w=55,flip=True);return
 # Fixed sclera with separately moving pupil, clipped to its boundary.
 w,h=61,79;yy,xx=np.mgrid[:h,:w];rr=((xx-(w-1)/2)/((w-2)/2))**2+((yy-(h-1)/2)/((h-2)/2))**2
 a=np.uint8(np.clip((1-rr)*12,0,1)*255);shade=np.uint8(np.clip(250-23*rr+4*(.5-yy/h),215,255))
 arr=np.dstack([shade,shade,np.minimum(shade.astype(int)+1,255).astype(np.uint8),a]);im=Image.fromarray(arr)
 pupil=fitted('eyes-open-l',29,39);im.alpha_composite(pupil,(round((w-pupil.width)/2+gaze[0]),round((h-pupil.height)/2+gaze[1])))
 mask=Image.fromarray(a)
 if half or closed>.01:
  cut=round(h*(.34 if half else .04)+closed*h*.6);aa=np.array(mask);aa[:cut]=0;mask=Image.fromarray(aa)
 im.putalpha(mask);canvas.alpha_composite(im,(round(x-w/2),round(y-h/2)))
def eye_pair(canvas,mode,t,gaze=(0,0),happy=False):
 b=blink(t)
 for side,x in [('l',185),('r',327)]:
  if mode=='happy':put(canvas,'eyes-happy-'+side,(x,217),w=57)
  elif mode=='sleep':put(canvas,'eyes-happy-'+side,(x,221),w=57,flip=True)
  elif mode=='angry':put(canvas,'eyes-angry-'+side,(x,201),w=78)
  elif mode=='pleading':oval_eye(canvas,x,228,b,side,'pleading')
  elif mode in ['white','half']:white_eye(canvas,x,220,gaze,mode=='half',b)
  elif mode=='wink':oval_eye(canvas,x,216,max(b,1 if side=='r' and happy else 0),side)
  else:oval_eye(canvas,x,216,b,side)
def brows(canvas,kind='raised',dy=0,right_raise=0):
 put(canvas,'brows-'+kind+'-l',(184,168+dy),w=60)
 put(canvas,'brows-'+kind+'-r',(328,168+dy-right_raise),w=60)
def mouth(canvas,name='smile',g=0,xy=(256,316),w=None,angle=0):
 default={'smile':141,'laugh':164,'oh':48,'frown':104,'flat':91,'kiss':25,'grin':176}
 width=w or default.get(name,140)
 if name in ['laugh','oh']:
  im=fitted(name,round(width),None);height=im.height*(.78+.22*g)
  put(canvas,name,xy,w=width,h=height,angle=angle)
 else:put(canvas,name,xy,w=width,angle=angle)

def render(stem,fi):
 name=stem.removeprefix('emoji-');t=fi/N;g=action(t);wave=math.sin(2*math.pi*t)
 canvas=Image.new('RGBA',(SIZE,SIZE));face=Image.new('RGBA',(SIZE,SIZE))
 if name=='heart':
  beat=.085*pulse(t,.35,.08)+.055*pulse(t,.53,.07);put(canvas,'original-heart',(256,256),w=344*(1+beat));return canvas
 if name=='approve':put(canvas,'original-approve',(256,263-7*g),h=334,angle=-7*g);return canvas
 if name=='fire':
  put(canvas,'original-fire',(256,276),h=370*(1+.015*wave),angle=1.6*wave)
  d=ImageDraw.Draw(canvas)
  for i in range(3):
   phase=(t+i/3)%1;alpha=round(160*math.sin(math.pi*phase));x=240+(i-1)*37;y=170-85*phase
   d.ellipse((x-3,y-5,x+3,y+5),fill=(255,187,46,alpha))
  return canvas
 if name=='thanks':
  hand=fitted('hand-prayer',None,315);alpha=np.array(hand.getchannel('A'))
  yy=round(hand.height*.3);xx=int(np.where(alpha[yy]>128)[0].min())
  for side in [-1,1]:
   im=ImageOps.mirror(hand) if side<0 else hand
   anchor_x=hand.width-1-xx if side<0 else xx
   at=(256+side*6*(1-g),209)
   pl=Image.new('RGBA',(512,512));pl.alpha_composite(im,(round(at[0]-anchor_x),round(at[1]-yy)))
   canvas.alpha_composite(pl.rotate(side*4*(1-g),resample=Image.Resampling.BICUBIC,center=at))
  return canvas
 if name=='clap':
  c=pulse(t,.34,.07)+pulse(t,.58,.07)
  put(canvas,'hand-clap',(283+16*(1-c),245-9*(1-c)),h=294,angle=-7)
  put(canvas,'hand-clap',(221-16*(1-c),292+9*(1-c)),h=294,angle=8)
  if c>.3:
   d=ImageDraw.Draw(canvas)
   for i in range(3):d.line([(200+i*24,92),(192+i*28,68)],fill=(245,173,18,round(255*c)),width=7)
  return canvas
 if name=='mindblown':
  put(canvas,'explosion',(256,165-8*g),w=270*(1+.06*g))
  im=fitted('base',320,320).copy();a=np.array(im.getchannel('A'));yy,xx=np.mgrid[:320,:320];cut=85+14*(1-np.abs(((xx%54)/27)-1));a[yy<cut]=0;im.putalpha(Image.fromarray(a));canvas.alpha_composite(im,(96,155))
 else:put(canvas,'base',(256,256),w=392,h=392)
 if name=='smile':eye_pair(face,'happy' if .32<t<.55 else 'open',t);mouth(face,'smile',w=141+4*g)
 elif name in ['laugh','rofl']:
  eye_pair(face,'happy',t);mouth(face,'laugh',g)
  for x,side in [(134,-1),(378,1)]:put(face,'tear',(x,260+13*g),h=65,angle=side*17)
 elif name=='kiss':
  eye_pair(face,'wink',t,happy=g>.35);mouth(face,'kiss',xy=(263,310));brows(face,right_raise=5*g)
  put(face,'heart',(322+45*g,312-22*g),w=49+9*g,opacity=pulse(t,.48,.40))
 elif name=='love':
  for x,side in [(185,-1),(327,1)]:put(face,'heart',(x,215),w=84*(1+.055*g),angle=side*6)
  mouth(face,'laugh',g,w=144)
 elif name=='surprise':eye_pair(face,'open',t);brows(face,dy=-9*g);mouth(face,'oh',g,w=47+7*g)
 elif name=='sad':
  eye_pair(face,'open',t);brows(face,'worried');mouth(face,'frown')
  p=track(t,[(0,0),(.15,0),(.73,1),(1,1)]);put(face,'tear',(153,241+85*p),h=39,opacity=pulse(t,.46,.37))
 elif name=='angry':eye_pair(face,'angry',t);mouth(face,'frown',w=105-8*g)
 elif name=='party':
  eye_pair(face,'happy',t);mouth(face,'oh',g,w=34)
  put(face,'hat',(180,117),h=162,angle=-16+3*wave)
  # The right end of the mouthpiece remains attached to the lips during the blow.
  prop=fitted('blower',174,None);anchor=(prop.width*.965,prop.height*.23)
  pl=Image.new('RGBA',(512,512));pl.alpha_composite(prop,(round(256-anchor[0]),round(316-anchor[1])))
  face.alpha_composite(pl.rotate(-3*g,resample=Image.Resampling.BICUBIC,center=(256,316)))
  d=ImageDraw.Draw(face)
  for i in range(7):
   p=(t+i/7)%1;x=76+i*59+10*math.sin(p*6.28);y=62+p*205;alpha=round(190*math.sin(math.pi*p))
   d.rectangle((x,y,x+5,y+9),fill=([(250,140,70),(90,180,245),(245,204,62)][i%3]+(alpha,)))
 elif name=='wink':eye_pair(face,'wink',t,happy=g>.22);brows(face,right_raise=7*g);mouth(face,'smile',angle=-3*g)
 elif name=='smirk':eye_pair(face,'half',t,gaze=(7*g,0));mouth(face,'smile',w=130,angle=-12-3*g);brows(face,right_raise=4*g)
 elif name=='eyeroll':
  gx=track(t,[(0,0),(.2,0),(.38,-8),(.54,0),(.7,8),(.91,0),(1,0)]);gy=-14*g
  eye_pair(face,'white',t,gaze=(gx,gy));brows(face);mouth(face,'flat')
 elif name=='sleepy':eye_pair(face,'sleep',t);brows(face,dy=4);mouth(face,'oh',g,w=38+15*g)
 elif name=='thinking':eye_pair(face,'open',t);brows(face,right_raise=10*g);mouth(face,'flat',xy=(268,302),angle=-7);put(face,'hand-think',(225+3*g,350-5*g),w=155,angle=3*g)
 elif name=='giggle':eye_pair(face,'happy',t);mouth(face,'laugh',g,w=143);put(face,'hand-cover',(269,355-29*g),h=140,angle=-3*g)
 elif name=='cool':eye_pair(face,'open',t);mouth(face,'smile');put(face,'glasses',(256,215+31*g),w=306,angle=-2*g)
 elif name=='grin':eye_pair(face,'happy',t);brows(face);mouth(face,'grin',xy=(256,314-3*g),w=177+4*g)
 elif name=='tongue':
  eye_pair(face,'wink',t,happy=g>.2);brows(face,right_raise=6*g);mouth(face,'smile',xy=(256,304),w=145)
  if g>.02:
   im=fitted('tongue',59,None);hh=max(2,round(im.height*g));put(face,'tongue',(258,309+hh/2),w=59,h=hh)
 elif name=='relieved':eye_pair(face,'sleep' if g>.2 else 'half',t);brows(face,dy=5*g);mouth(face,'smile',w=121)
 elif name=='skeptical':eye_pair(face,'open',t);brows(face,right_raise=14+8*g);mouth(face,'flat',angle=-2)
 elif name=='unamused':eye_pair(face,'half',t,gaze=(8*wave,1));brows(face,dy=3);mouth(face,'frown',w=99)
 elif name=='pleading':eye_pair(face,'pleading',t);brows(face,'worried',dy=-4);mouth(face,'frown',w=61)
 elif name=='starry':
  for x,side in [(181,-1),(331,1)]:put(face,'star',(x,217),w=101*(1+.045*g),angle=side*7*wave)
  brows(face,dy=-6);mouth(face,'laugh',g,w=159)
 elif name=='zipper':
  eye_pair(face,'open',t);put(face,'zipper-body',(236,319),w=162)
  put(face,'zipper-pull',(345,341),w=61,angle=8*wave)
 elif name=='shush':eye_pair(face,'open',t);brows(face);mouth(face,'oh',w=29);put(face,'hand-shush',(264,408-40*g),h=174)
 elif name=='hugging':
  eye_pair(face,'happy',t);brows(face);mouth(face,'laugh',g,w=145)
  put(face,'hand-open',(130+31*g,385-10*g),h=163,angle=-17+13*g)
  put(face,'hand-open',(382-31*g,385-10*g),h=163,angle=17-13*g,mirror=True)
 elif name=='salute':eye_pair(face,'open',t);brows(face);mouth(face,'smile');put(face,'hand-salute',(159,253-80*g),w=199,angle=3*(1-g))
 elif name=='sweat':
  eye_pair(face,'happy',t);brows(face);mouth(face,'laugh',g,w=151)
  progress=track(t,[(0,0),(.12,0),(.73,1),(1,1)]);put(face,'tear',(142,154+101*progress),h=65,opacity=pulse(t,.45,.4))
 elif name=='mindblown':eye_pair(face,'open',t);brows(face);mouth(face,'oh',g,w=63)
 elif name=='sobbing':
  d=ImageDraw.Draw(face)
  for x,side in [(185,-1),(327,1)]:d.line([(x-side*19,202),(x+side*15,218),(x-side*19,230)],fill='#653207',width=14,joint='curve')
  brows(face,'worried');mouth(face,'oh',g,xy=(256,331),w=66)
  # Fixed tear streams start directly beneath the eyes; only the rounded ends descend.
  for x in [168,344]:
   length=136+24*g;d.rounded_rectangle((x-19,227,x+19,227+length),radius=17,fill='#48c8ef')
   d.rounded_rectangle((x-10,234,x-4,221+length),radius=3,fill='#b2efff')
 elif name=='angel':eye_pair(face,'sleep' if g>.4 else 'open',t);mouth(face,'smile',w=124);put(face,'halo',(256,92-3*wave),w=291,angle=4*wave)
 else:raise ValueError(stem)
 if name in ['laugh','rofl']:
  angle=(5 if name=='laugh' else 17)*math.sin(4*math.pi*t)*g
  face=face.rotate(angle,resample=Image.Resampling.BICUBIC,center=(256,256))
 if name=='mindblown':face=face.resize((418,418),Image.Resampling.LANCZOS);canvas.alpha_composite(face,(47,105))
 else:canvas.alpha_composite(face)
 return canvas

ITEMS=[x for x in json.loads((ROOT.parent/'matcha-motion-v6/manifest.json').read_text(encoding='utf-8')) if x['kind']=='emoji']
def contact():
 out=Image.new('RGB',(1200,1200),'#f4f3ea');d=ImageDraw.Draw(out)
 for i,item in enumerate(ITEMS):
  im=render(item['id'],70);bg=Image.new('RGBA',im.size,'#f4f3ea');bg.alpha_composite(im);out.paste(bg.resize((180,180)).convert('RGB'),((i%6)*200+10,(i//6)*200));d.text(((i%6)*200+7,(i//6)*200+183),item['id'],fill='#30382a')
 out.save(OUT/'all-36-contact.jpg',quality=91);print('36 emoji key poses rendered',flush=True)
def build(item):
 stem=item['id'];frames=[render(stem,i) for i in range(N)]
 frames[0].save(OUT/(stem+'.png'))
 frames[0].save(OUT/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=MS,loop=0,quality=94,method=1,alpha_quality=100)
 strip=Image.new('RGB',(1200,200),'#f4f3ea')
 for j,fi in enumerate([0,30,55,75,105,135]):
  bg=Image.new('RGBA',(512,512),'#f4f3ea');bg.alpha_composite(frames[fi]);strip.paste(bg.resize((200,200)).convert('RGB'),(j*200,0))
 strip.save(OUT/(stem+'-phases.jpg'),quality=90)
 print(stem+' stable-layer loop ready',flush=True)
 return stem
if __name__=='__main__':
 contact()
 if '--contact' not in sys.argv:
  from concurrent.futures import ThreadPoolExecutor,as_completed
  selected=ITEMS if '--sample' not in sys.argv else [x for x in ITEMS if x['id'] in ['emoji-laugh','emoji-eyeroll','emoji-hugging','emoji-shush','emoji-clap','emoji-mindblown']]
  with ThreadPoolExecutor(max_workers=3) as pool:
   for f in as_completed([pool.submit(build,item) for item in selected]):f.result()
  print(str(len(selected))+' emoji prototypes rendered')
