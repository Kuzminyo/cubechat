from pathlib import Path
import importlib.util,sys,math,json,shutil
from functools import lru_cache
from PIL import Image,ImageDraw,ImageFilter,ImageOps
import numpy as np
ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('rig',ROOT/'build-rig-prototype.py');rig=importlib.util.module_from_spec(spec);spec.loader.exec_module(rig)
OUT=ROOT/'cat-rig';OUT.mkdir(exist_ok=True);PARTS=ROOT/'cat-props';PARTS.mkdir(exist_ok=True)
source=ROOT/'cat-source-props.png'
if not source.exists():shutil.copy2('C:/Users/kuzme/.codex/generated_images/01a07721-3949-7910-9e64-eaae4d5bf0e0/exec-25bc9018-834f-43c6-ac93-c870df89a83f.png',source)
sheet=Image.open(source).convert('RGB');W,H=sheet.size
names=['heart','cup','glasses','hourglass','blanket','cookie','laptop','cake','headphones','controller','umbrella','box','pom-coral','pom-cream','scarf','popcorn','hat','bandage','tail','cushion']
parts={}
for i,name in enumerate(names):
 im=rig.key(sheet.crop((round(i%5*W/5),round(i//5*H/4),round((i%5+1)*W/5),round((i//5+1)*H/4))))
 parts[name]=im;im.save(PARTS/(name+'.png'))
SIZE=512;N=150;MS=40
ITEMS=[x for x in json.loads((ROOT.parent/'matcha-motion-v6/manifest.json').read_text(encoding='utf-8')) if x['kind']=='cat']
@lru_cache(maxsize=200)
def fit(name,w=None,h=None):
 im=parts[name]
 if w is None:w=round(im.width*h/im.height)
 if h is None:h=round(im.height*w/im.width)
 return im.resize((round(w),round(h)),Image.Resampling.LANCZOS)
def put(canvas,name,xy,w=None,h=None,angle=0):canvas.alpha_composite(rig.layer(fit(name,w,h),xy,angle=angle))
def pulse(t,c,w):return 0 if abs(t-c)>=w else .5+.5*math.cos(math.pi*(t-c)/w)
def act(t):return rig.channel(t,[(0,0),(.13,0),(.36,1),(.63,1),(.90,0),(1,0)])
def outline(frame):
 out=Image.new('RGBA',frame.size,(255,255,250,0));out.putalpha(Image.fromarray(rig.cv2.dilate(np.array(frame.getchannel('A')),np.ones((7,7),np.uint8))).filter(ImageFilter.GaussianBlur(.3)));out.alpha_composite(frame);return out
@lru_cache(maxsize=4)
def original(stem):return Image.open(ROOT.parent/'matcha-motion-v6/masters'/(stem+'.png')).convert('RGBA')
def sleepy(stem,t,g):
 # These two approved poses already contain the resting body. A rigid, tiny breath
 # preserves its drawing, with separate sleepy glyphs providing the visible action.
 im=original(stem);im=ImageOps.contain(im,(448,356));base=Image.new('RGBA',(512,512));base.alpha_composite(im,((512-im.width)//2,round(302-im.height/2+2*math.sin(t*math.tau))))
 if stem=='cat-tired':base=base.rotate(-2*g,resample=Image.Resampling.BICUBIC,center=(256,402))
 layer=Image.new('RGBA',(512,512));d=ImageDraw.Draw(layer)
 for i in range(3):
  phase=(t+i/3)%1;a=round(220*math.sin(math.pi*phase));x=310+phase*72;y=137-phase*83;sz=10+9*phase
  d.line([(x,y),(x+sz,y),(x,y+sz),(x+sz,y+sz)],fill=(93,111,73,a),width=3)
 base.alpha_composite(layer);return base

def draw_face(frame,t,g,mood='open',mouth='closed'):
 # Facial features use fixed positions. Blinks are short eyelid closures only.
 b=rig.blink(t);happy=mood=='happy';eyes=rig.eyes_closed if happy or b>.87 else rig.eyes_open
 if mood=='sleep':eyes=ImageOps.flip(rig.eyes_closed)
 if mood=='half':
  eyes=rig.eyes_open.copy();aa=np.array(eyes.getchannel('A'));aa[:round(eyes.height*.38)]=0;eyes.putalpha(Image.fromarray(aa))
 if mood=='wink':
  eyes=Image.new('RGBA',rig.eyes_open.size);mid=eyes.width//2
  eyes.alpha_composite(rig.eyes_open.crop((0,0,mid,eyes.height)),(0,0));closed=rig.eyes_closed.crop((rig.eyes_closed.width//2,0,rig.eyes_closed.width,rig.eyes_closed.height));eyes.alpha_composite(closed,(mid,(eyes.height-closed.height)//2))
 rig.paste(frame,eyes,(256,211))
 d=ImageDraw.Draw(frame)
 if mood in ['sad','angry','thinking']:
  for side in [-1,1]:
   x=256+side*53;dy=(7 if mood=='sad' else -8)*side
   d.line([(x-16,176+dy),(x+16,176-dy)],fill='#5b5838',width=5)
 blush=Image.new('RGBA',(512,512));dd=ImageDraw.Draw(blush)
 for x in [181,331]:dd.ellipse((x-17,235,x+17,252),fill=(234,130,118,75 if mood!='shy' else 130))
 frame.alpha_composite(blush.filter(ImageFilter.GaussianBlur(6)))
 d=ImageDraw.Draw(frame);d.ellipse((251,244,261,250),fill='#d79785');d.polygon([(252,247),(260,247),(256,251)],fill='#d79785')
 if mouth=='open':
  im=rig.mouth_open;im=im.resize((im.width,round(im.height*(.65+.35*g))),Image.Resampling.LANCZOS);frame.alpha_composite(im,(256-im.width//2,255))
 elif mouth=='oh':d.ellipse((249,259,263,279),fill='#654331')
 elif mouth=='frown':d.arc((247,261,265,276),180,360,fill='#654331',width=3)
 else:rig.paste(frame,rig.mouth_closed,(256,261))
 for side in [-1,1]:
  for dy in [-8,0,8]:d.line([(256+side*103,248+dy),(256+side*126,246+dy*1.4)],fill='#5c5b3b',width=2)

def smooth_arm(im,shoulder,target,side):
 # Rounded rigid segments prevent the diagonal crop edges from showing at elbows.
 origin=np.array(shoulder,float);goal=np.array(target,float);axis=goal-origin;distance=np.linalg.norm(axis)
 l1,l2=64.,52.;u=axis/max(distance,.01);distance=np.clip(distance,abs(l1-l2)+.1,l1+l2-.1);goal=origin+u*distance
 along=(l1*l1-l2*l2+distance*distance)/(2*distance);height=math.sqrt(max(0,l1*l1-along*along));elbow=origin+u*along+np.array([-u[1],u[0]])*(-side)*height
 def segment(a,b):
  layer=Image.new('RGBA',(512,512));d=ImageDraw.Draw(layer)
  for color,width in [('#565736',34),('#9d9e70',28)]:
   d.line([tuple(a),tuple(b)],fill=color,width=width)
   for x,y in [a,b]:d.ellipse((x-width/2,y-width/2,x+width/2,y+width/2),fill=color)
  return layer
 pix=np.array(im);pink=(pix[:,:,3]>180)&(pix[:,:,0].astype(float)-pix[:,:,1]>40)&(pix[:,:,0].astype(float)-pix[:,:,2]>50)
 ys,xs=np.where(pink & (np.arange(im.height)[:,None]>im.height*.65));center=(float(xs.mean()),float(ys.mean()))
 crop_top=round(im.height*.72);paw=im.crop((0,crop_top,im.width,im.height));pivot=(center[0],center[1]-crop_top)
 angle=math.degrees(math.atan2((goal-elbow)[0],(goal-elbow)[1]));hand=rig.layer(paw,tuple(goal),pivot,angle)
 return segment(origin,elbow),segment(elbow,goal),hand
rig.ik_arm=smooth_arm

def running(t,g):
 # Retain the approved running silhouette; the stride is a slow hop with quiet holds.
 im=ImageOps.contain(original('cat-hurry'),(444,396));out=Image.new('RGBA',(512,512));phase=math.sin(math.tau*2*t);jump=abs(phase)*g
 out.alpha_composite(im,((512-im.width)//2,round(283-im.height/2-10*jump)))
 out=out.rotate(3*phase*g,resample=Image.Resampling.BICUBIC,center=(256,376))
 return out

def render(stem,fi):
 if stem in ['cat-morning','cat-laugh','cat-flower','cat-victory']:return rig.render(stem,fi)
 t=fi/N;g=act(t);wave=math.sin(math.tau*t);c=math.sin(math.tau*2*t)*g;name=stem[4:]
 if name in ['sleep','tired']:return sleepy(stem,t,g)
 if name=='hurry':return running(t,g)
 mood='open';mouth='closed';tilt=0;arms=[-12,12];targets=[None,None];prop=None;prop_xy=(256,350);prop_w=100;prop_h=None;prop_angle=0;hands_front=True
 # Each gesture has its own path and quiet hold. Prop grips and hands share targets.
 if name=='wave':arms=[-24-112*g+9*c,12];mood='happy' if g>.4 else 'open';mouth='open' if g>.4 else 'closed'
 elif name=='love':prop='heart';prop_w=137;prop_xy=(256,342-14*g);targets=[(218,348-14*g),(294,348-14*g)];mood='happy' if g>.4 else 'open'
 elif name=='approve':arms=[-26-67*g,12];mood='happy' if g>.4 else 'open';tilt=-2*g
 elif name=='shy':targets=[(198+7*g,316-56*g),(314-7*g,316-56*g)];mood='happy';tilt=3*g
 elif name=='sad':targets=[(220,397),(292,397)];mood='sad';mouth='frown';tilt=3*g
 elif name=='angry':targets=[(201,335-15*g),(311,335-15*g)];mood='angry';mouth='frown'
 elif name=='party':arms=[-20-113*g,20+113*g];mood='happy' if g>.4 else 'open';mouth='open'
 elif name=='surprise':targets=[(196,310-35*g),(316,310-35*g)];mouth='oh'
 elif name=='matcha':prop='cup';prop_w=132;prop_xy=(256,347-62*g);targets=[(212,354-62*g),(300,354-62*g)];mood='happy' if g>.4 else 'open'
 elif name=='cool':arms=[-17-108*g,12];tilt=-3*g
 elif name=='thanks':targets=[(246-13*(1-g),326),(266+13*(1-g),326)];mood='happy';mouth='open';tilt=4*g
 elif name=='thinking':targets=[(232,319-51*g),None];mood='thinking';tilt=-4*g
 elif name=='facepalm':targets=[(216,332-103*g),None];mood='sleep';tilt=4*g
 elif name=='hug':targets=[(159+69*g,332),(353-69*g,338)];mood='happy';mouth='open'
 elif name=='waiting':prop='hourglass';prop_h=114;prop_w=None;prop_xy=(256,351);targets=[(230,355),(282,355)];mood='half';tilt=2*wave;prop_angle=180*g
 elif name=='sorry':targets=[(244-8*(1-g),333),(268+8*(1-g),333)];mood='sad';mouth='frown';tilt=5*g
 elif name=='cozy':mood='sleep';targets=[(231,331),(281,331)]
 elif name=='cookie':prop='cookie';prop_w=98;prop_xy=(244,341-51*g);targets=[(224,355-51*g),(289,350-51*g)];mood='happy';mouth='open' if g>.6 else 'closed'
 elif name=='work':targets=[(218,353-7*c),(330,417-5*c)];mood='thinking';hands_front=False
 elif name=='hurry':arms=[-27+34*c,27-34*c];mood='open';mouth='open';tilt=-11
 elif name=='birthday':prop='cake';prop_w=160;prop_xy=(256,353-12*g);targets=[(204,372-12*g),(308,372-12*g)];mood='happy';mouth='open'
 elif name=='nope':targets=[(215+70*g,337),(297-70*g,319)];mood='angry';mouth='frown';tilt=4*c
 elif name=='music':arms=[-12-6*c,12+6*c];mood='sleep';tilt=4*c
 elif name=='gaming':prop='controller';prop_w=170;prop_xy=(256,343);targets=[(196,337+3*c),(316,337-3*c)];mood='thinking'
 elif name=='rain':targets=[(284,342),None];mood='sad';mouth='frown'
 elif name=='peek':mood='open';mouth='open';targets=[(204,345),(308,345)]
 elif name=='secret':targets=[(245,329-58*g),None];mood='wink' if g>.4 else 'open'
 elif name=='support':targets=[(157,335-93*g),(355,335-93*g)];mood='happy';mouth='open'
 elif name=='recover':targets=[(216,375),(296,375)];mood='open';tilt=2*g
 elif name=='popcorn':prop='popcorn';prop_w=126;prop_xy=(256,359);targets=[(223,339-70*g),(294,361)];mood='happy' if g>.5 else 'open';mouth='open' if g>.5 else 'closed'
 else:raise ValueError(stem)
 frame=Image.new('RGBA',(512,512));frame.alpha_composite(rig.layer(rig.tail,(351,433),(19,rig.tail.height-15),-5*wave))
 shoulders=[(182,305),(330,305)];ims=[rig.left,rig.right];fronts=[rig.lf,rig.rf];arm_layers=[]
 for i,(shoulder,im) in enumerate(zip(shoulders,ims)):
  if targets[i]:
   upper,forearm,hand=rig.ik_arm(im,shoulder,targets[i],-1 if i==0 else 1);frame.alpha_composite(upper);arm_layers.append((forearm,hand))
  else:
   frame.alpha_composite(rig.layer(im,shoulder,(im.width*.5,15),arms[i]));arm_layers.append((None,rig.layer(fronts[i],shoulder,(im.width*.5,15),arms[i])))
 if name=='hurry':
  # Feet swing as separate rigid pieces; the body itself is never warped.
  core=rig.core.copy();pixels=np.array(core);cut=int(core.height*.85);pixels[cut:,:,3]=0;core.putalpha(Image.fromarray(pixels[:,:,3]));rig.paste(frame,core,(256,251))
  for i in [0,1]:
   feet=rig.core.crop((int(i*rig.core.width/2),cut,int((i+1)*rig.core.width/2),rig.core.height));frame.alpha_composite(rig.layer(feet,(218+i*77,428+(1 if i==0 else -1)*9*c),angle=(1 if i==0 else -1)*20*c))
 else:rig.paste(frame,rig.core,(256,251))
 draw_face(frame,t,g,mood,mouth)
 for forearm,hand in arm_layers:
  if forearm is not None:frame.alpha_composite(forearm)
 if prop:put(frame,prop,prop_xy,w=prop_w,h=prop_h,angle=prop_angle)
 if name=='cozy':put(frame,'blanket',(256,372),w=278)
 if name=='rain':put(frame,'umbrella',(259,203),h=372)
 if name=='recover':put(frame,'scarf',(256,343),w=190,h=158);put(frame,'bandage',(315,164),w=53)
 for forearm,hand in arm_layers:frame.alpha_composite(hand)
 if name=='cool':put(frame,'glasses',(256,211+7*g),w=253)
 if name=='party':put(frame,'hat',(222,86),h=139,angle=-12)
 if name=='music':put(frame,'headphones',(256,148),w=352,h=267)
 if name=='work':
  put(frame,'laptop',(227,402),w=242)
  frame.alpha_composite(arm_layers[1][1])
 if name=='support':
  for prop_name,xy in [('pom-coral',targets[0]),('pom-cream',targets[1])]:put(frame,prop_name,(xy[0],xy[1]-14),w=116,angle=7*c)
 if name=='popcorn':
  put(frame,'popcorn',(256,367),w=126)
  # The small kernel follows the eating paw, including the quiet hold near the mouth.
  if g>.05:
   d=ImageDraw.Draw(frame);x,y=targets[0];d.ellipse((x-6,y-10,x+6,y+2),fill='#ffe9ac',outline='#ad9458',width=2)
 if name in ['surprise','approve','birthday','support']:
  d=ImageDraw.Draw(frame)
  for side in [-1,1]:
   if g>.25:
    x=256+side*153;y=198-8*wave;d.line([(x,y-9),(x,y+9)],fill='#eac966',width=3);d.line([(x-7,y),(x+7,y)],fill='#eac966',width=3)
 if name=='angry':
  fx=Image.new('RGBA',(512,512));d=ImageDraw.Draw(fx);alpha=round(180*g);d.arc((226,14,251,38),110,350,fill=(201,192,158,alpha),width=4);d.arc((242,14,271,39),190,420,fill=(201,192,158,alpha),width=4);frame.alpha_composite(fx)
 if name=='matcha':
  steam=Image.new('RGBA',(512,512));d=ImageDraw.Draw(steam)
  for i in range(2):
   x=243+i*22;y=prop_xy[1]-55;d.arc((x-6,y-38-4*wave,x+7,y-8-4*wave),75,275,fill=(255,248,225,round(150*(1-g*.7))),width=4)
  frame.alpha_composite(steam)
 if name=='party':
  fx=Image.new('RGBA',(512,512));d=ImageDraw.Draw(fx)
  for i in range(8):
   p=(t+i/8)%1;x=62+i*55;y=90+135*p;d.rectangle((x,y,x+5,y+9),fill=[(237,161,149,int(190*math.sin(math.pi*p))),(153,181,131,int(190*math.sin(math.pi*p)))][i%2])
  frame.alpha_composite(fx)
 if name=='rain':
  fx=Image.new('RGBA',(512,512));d=ImageDraw.Draw(fx)
  for i,x in enumerate([81,408,109,386]):
   p=(t+i*.25)%1;y=181+178*p;d.line([(x,y),(x-3,y+9)],fill=(136,185,194,round(190*math.sin(math.pi*p))),width=5)
  frame.alpha_composite(fx)
 if name=='peek':
  moved=Image.new('RGBA',(512,512));moved.alpha_composite(frame,(0,round(91*(1-g))));frame=moved
  # The opaque box front occludes the body throughout the reveal.
  a=np.array(frame.getchannel('A'));a[354:]=0;frame.putalpha(Image.fromarray(a));put(frame,'box',(256,384),w=321)
 if tilt:frame=frame.rotate(tilt,resample=Image.Resampling.BICUBIC,center=(256,416))
 if name=='hurry':
  shifted=Image.new('RGBA',(512,512));shifted.alpha_composite(frame,(round(4*wave),round(-4*abs(c))));frame=shifted
 return outline(frame)

def contact():
 out=Image.new('RGB',(1200,1200),'#f4f3ea');d=ImageDraw.Draw(out)
 for i,item in enumerate(ITEMS):
  im=render(item['id'],65);bg=Image.new('RGBA',im.size,'#f4f3ea');bg.alpha_composite(im);out.paste(bg.resize((180,180)).convert('RGB'),((i%6)*200+10,(i//6)*200));d.text(((i%6)*200+7,(i//6)*200+183),item['id'],fill='#30382a')
 out.save(OUT/'all-36-contact.jpg',quality=91);print('36 cat key poses rendered',flush=True)
def build(item):
 stem=item['id'];frames=[render(stem,i) for i in range(N)];frames[0].save(OUT/(stem+'.png'));frames[0].save(OUT/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=MS,loop=0,quality=94,method=1,alpha_quality=100)
 strip=Image.new('RGB',(1200,200),'#f4f3ea')
 for j,fi in enumerate([0,30,55,75,105,135]):
  bg=Image.new('RGBA',(512,512),'#f4f3ea');bg.alpha_composite(frames[fi]);strip.paste(bg.resize((200,200)).convert('RGB'),(j*200,0))
 strip.save(OUT/(stem+'-phases.jpg'),quality=90);print(stem+' articulated loop ready',flush=True);return stem
if __name__=='__main__':
 contact()
 if '--contact' not in sys.argv:
  from concurrent.futures import ThreadPoolExecutor,as_completed
  selected=[x for x in ITEMS if '--resume' not in sys.argv or not (OUT/(x['id']+'-phases.jpg')).exists()] if '--sample' not in sys.argv else [x for x in ITEMS if x['id'] in ['cat-matcha','cat-hurry','cat-peek','cat-hug','cat-support','cat-facepalm']]
  with ThreadPoolExecutor(max_workers=3) as pool:
   for f in as_completed([pool.submit(build,item) for item in selected]):f.result()
  print(str(len(selected))+' cat prototypes rendered')
