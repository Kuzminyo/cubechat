from pathlib import Path
import sys,math,json,shutil
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import cv2,numpy as np
from PIL import Image,ImageDraw,ImageFilter,ImageOps
ROOT=Path(__file__).resolve().parent
(ROOT/'parts').mkdir(exist_ok=True)
SRC=Path('C:/Users/kuzme/.codex/generated_images/01a07721-3949-7910-9e64-eaae4d5bf0e0/exec-ecd9042c-5201-4bc1-92fa-9571cf720ad5.png')
if not (ROOT/'rig-sheet.png').exists():shutil.copy2(SRC,ROOT/'rig-sheet.png')
sheet=Image.open(ROOT/'rig-sheet.png').convert('RGB');W,H=sheet.size
REGIONS={'core':(.045,.015,.285,.425),'arm-left':(.34,.09,.475,.395),'arm-right':(.575,.09,.705,.395),'tail':(.77,.07,.97,.415),'eyes-open':(.045,.48,.24,.60),'eyes-closed':(.30,.50,.49,.585),'mouth-open':(.58,.50,.68,.625),'mouth-closed':(.80,.515,.895,.59),'flower':(.06,.65,.225,.96),'trophy':(.30,.67,.49,.94),'tears':(.555,.755,.705,.88),'sparkle':(.81,.75,.905,.88)}
def key(im):
 rgb=np.array(im).astype(np.float32);d=np.minimum(rgb[:,:,0],rgb[:,:,2])-rgb[:,:,1]
 bg=(d>65)&(rgb[:,:,0]>100)&(rgb[:,:,2]>100)
 edge=cv2.dilate(bg.astype(np.uint8),np.ones((5,5),np.uint8))>0
 a=np.ones(d.shape,np.float32);a[edge]=np.clip(1-d[edge]/90,0,1);a[bg]=0
 rgb=np.clip((rgb-(1-a[:,:,None])*np.array([255,0,255]))/np.maximum(a[:,:,None],.001),0,255)
 out=Image.fromarray(np.dstack((rgb.astype(np.uint8),np.uint8(a*255))))
 box=out.getchannel('A').point(lambda v:255 if v>80 else 0).getbbox()
 return out.crop(box)
parts={}
for name,rect in REGIONS.items():
 im=key(sheet.crop(tuple(round(v*(W if i%2==0 else H)) for i,v in enumerate(rect))))
 # Strip only the white edging connected to the outside. Internal eye highlights remain.
 pixels=np.array(im);rgb=pixels[:,:,:3].astype(float)
 eligible=(pixels[:,:,3]<32)|((rgb.min(2)>195)&((rgb.max(2)-rgb.min(2))<45))
 _,labels=cv2.connectedComponents(eligible.astype(np.uint8),4)
 outside=set(labels[0])|set(labels[-1])|set(labels[:,0])|set(labels[:,-1]);outside.discard(0)
 strip=np.isin(labels,list(outside));pixels[strip,3]=0
 im=Image.fromarray(pixels)
 im.save(ROOT/'parts'/(name+'.png'));parts[name]=im
SIZE=512;N=150

def fit(name,w=None,h=None):
 im=parts[name]
 if w is None:w=round(im.width*h/im.height)
 if h is None:h=round(im.height*w/im.width)
 return im.resize((w,h),Image.Resampling.LANCZOS)
core=fit('core',h=414)
left=fit('arm-left',h=142);right=fit('arm-right',h=142)
# The proximal end is hidden under the body. Only the paw is composited in front.
def distal(im):
 out=im.copy();a=np.array(im.getchannel('A')).astype(float);ramp=np.clip((np.arange(im.height)/im.height-.60)/.15,0,1)
 out.putalpha(Image.fromarray(np.uint8(a*ramp[:,None])));return out
lf=distal(left);rf=distal(right)
tail=fit('tail',h=163)
eyes_open=fit('eyes-open',w=168);eyes_closed=fit('eyes-closed',w=168)
mouth_open=fit('mouth-open',w=44);mouth_closed=fit('mouth-closed',w=32)
flower=fit('flower',h=159);trophy=fit('trophy',h=138)
tears=parts['tears'];tear_left=tears.crop((0,0,tears.width//2,tears.height));tear_right=tears.crop((tears.width//2,0,tears.width,tears.height))

# Every non-facial part has constant scale and shape: these are rigid rotations/translations only.
def layer(im,at,pivot=None,angle=0):
 if pivot is None:pivot=(im.width/2,im.height/2)
 canvas=Image.new('RGBA',(SIZE,SIZE));canvas.alpha_composite(im,(round(at[0]-pivot[0]),round(at[1]-pivot[1])))
 return canvas.rotate(angle,resample=Image.Resampling.BICUBIC,center=at)
def paste(canvas,im,at):canvas.alpha_composite(layer(im,at))
def ease(t):return t*t*(3-2*t)
def channel(t,keys):
 for (ta,a),(tb,b) in zip(keys,keys[1:]):
  if ta<=t<=tb:return a+(b-a)*ease((t-ta)/(tb-ta))
 return keys[-1][1]
def blink(t,center=.82,width=.045):
 q=abs(t-center)/width
 return 0 if q>=1 else .5+.5*math.cos(math.pi*q)

def ik_arm(im,shoulder,target,side):
 # Two rigid segments share an elbow. The endpoint is fixed to the prop's grip.
 origin=np.array(shoulder,dtype=float);goal=np.array(target,dtype=float)
 pixels=np.array(im);pink=(pixels[:,:,3]>180)&(pixels[:,:,0].astype(float)-pixels[:,:,1]>40)&(pixels[:,:,0].astype(float)-pixels[:,:,2]>50)
  # Measured pad center is the grip anchor; don't assume the crop center is the hand.
 ys,xs=np.where(pink & (np.arange(im.height)[:,None]>im.height*.65))
 palm=np.array([float(xs.mean()),float(ys.mean())]) if len(xs) else np.array([im.width*.55,im.height*.84])
 native=palm-np.array([im.width*.5,79.])
 axis=goal-origin;distance=float(np.linalg.norm(axis));l1=64.;l2=float(np.linalg.norm(native))
 distance=min(l1+l2-.1,max(abs(l1-l2)+.1,distance));u=axis/np.linalg.norm(axis)
 a=(l1*l1-l2*l2+distance*distance)/(2*distance);height=math.sqrt(max(0,l1*l1-a*a))
 perp=np.array([-u[1],u[0]])*(-side);elbow=origin+u*a+perp*height
 upper=im.crop((0,0,im.width,99));lower=im.crop((0,64,im.width,im.height))
 def angle(v):return math.degrees(math.atan2(v[0],v[1]))
 proximal=layer(upper,tuple(origin),(im.width*.5,15),angle(elbow-origin))
 distal_layer=layer(lower,tuple(elbow),(im.width*.5,15),angle(goal-elbow)-angle(native))
 paw=lower.copy();alpha=np.array(paw.getchannel('A')).astype(float);ramp=np.clip((np.arange(paw.height)-35)/12,0,1)
 paw.putalpha(Image.fromarray(np.uint8(alpha*ramp[:,None])))
 hand=layer(paw,tuple(elbow),(im.width*.5,15),angle(goal-elbow)-angle(native))
 return proximal,distal_layer,hand

def render(stem,fi):
 t=fi/N;wave=math.sin(2*math.pi*t)
 gesture=channel(t,[(0,0),(.14,0),(.38,1),(.64,1),(.9,0),(1,0)])
 arms=(-12,12);smile=0;eye_happy=0;prop=None;tilt=0;raise_prop=0
 if stem=='cat-morning':arms=(-12-131*gesture,12+131*gesture);eye_happy=gesture;smile=gesture
 if stem=='cat-laugh':
  laugh=channel(t,[(0,0),(.14,0),(.24,1),(.68,1),(.86,0),(1,0)])
  bounce=math.sin(6*math.pi*t)*laugh
  arms=(-37-9*bounce,37+9*bounce);tilt=6*math.sin(4*math.pi*t)*laugh;smile=laugh;eye_happy=laugh
 if stem=='cat-flower':arms=(29,-29);prop=flower;raise_prop=66*gesture;eye_happy=gesture;smile=0
 if stem=='cat-victory':arms=(33,-33);prop=trophy;raise_prop=27*gesture;eye_happy=gesture;smile=gesture*.7
 frame=Image.new('RGBA',(SIZE,SIZE))
 frame.alpha_composite(layer(tail,(351,433),(19,tail.height-15),-6*wave))
 shoulder_l=(182,305);shoulder_r=(330,305);pivot_l=(left.width*.5,15);pivot_r=(right.width*.5,15)
 rigged=None
 if prop:
  py=364-raise_prop
  grips=((243,py+35),(269,py+35)) if stem=='cat-flower' else ((216,py-10),(296,py-10))
  rigged=[ik_arm(left,shoulder_l,grips[0],-1),ik_arm(right,shoulder_r,grips[1],1)]
  for upper,forearm,hand in rigged:frame.alpha_composite(upper)
 else:
  frame.alpha_composite(layer(left,shoulder_l,pivot_l,arms[0]));frame.alpha_composite(layer(right,shoulder_r,pivot_r,arms[1]))
 paste(frame,core,(256,251))
 blush=Image.new('RGBA',(SIZE,SIZE));brush=ImageDraw.Draw(blush)
 for bx in [181,331]:brush.ellipse((bx-18,233,bx+18,253),fill=(233,130,118,70))
 frame.alpha_composite(blush.filter(ImageFilter.GaussianBlur(6)))
 # Stable facial anchors. No optical flow or interpolation between independent full faces.
 b=blink(t)
 if eye_happy>.45 or b>.88:paste(frame,eyes_closed,(256,211))
 else:
  eye=eyes_open.resize((eyes_open.width,max(7,round(eyes_open.height*(1-.68*b)))),Image.Resampling.LANCZOS)
  paste(frame,eye,(256,211))
 draw=ImageDraw.Draw(frame)
 draw.ellipse((251,244,261,250),fill='#d79785');draw.polygon([(252,247),(260,247),(256,251)],fill='#d79785')
 if smile>.1:
  mouth=mouth_open.resize((mouth_open.width,max(8,round(mouth_open.height*(.18+.82*smile)))),Image.Resampling.LANCZOS)
  frame.alpha_composite(mouth,(256-mouth.width//2,255))
 else:paste(frame,mouth_closed,(256,261))
 # Whiskers have the same shape and placement through the complete loop.
 for side in [-1,1]:
  for dy in [-8,0,8]:draw.line([(256+side*103,248+dy),(256+side*126,246+dy*1.4)],fill='#5c5b3b',width=2)
 if prop:
  for upper,forearm,hand in rigged:frame.alpha_composite(forearm)
  paste(frame,prop,(256,364-raise_prop))
  for upper,forearm,hand in rigged:frame.alpha_composite(hand)
 else:
  frame.alpha_composite(layer(lf,shoulder_l,pivot_l,arms[0]));frame.alpha_composite(layer(rf,shoulder_r,pivot_r,arms[1]))
 if stem=='cat-laugh' and smile>.15:
  for side,im in [(-1,tear_left),(1,tear_right)]:
   im=ImageOps.contain(im,(22,32));paste(frame,im,(256+side*80,236+11*(.5+.5*math.sin(4*math.pi*t))))
 if stem=='cat-victory':
  spark=fit('sparkle',w=22)
  for side in [-1,1]:
   if gesture>.25:paste(frame,spark,(256+side*126,225-11*wave))
 if tilt:frame=frame.rotate(tilt,resample=Image.Resampling.BICUBIC,center=(256,416))
 # The sticker has one outer outline, not white seams around overlapping body parts.
 outline=Image.new('RGBA',frame.size,(255,255,250,0))
 outline.putalpha(Image.fromarray(cv2.dilate(np.array(frame.getchannel('A')),np.ones((7,7),np.uint8))).filter(ImageFilter.GaussianBlur(.3)))
 outline.alpha_composite(frame)
 return outline

def build(stem):
 frames=[render(stem,i) for i in range(N)]
 frames[0].save(ROOT/(stem+'-rig.png'))
 frames[0].save(ROOT/(stem+'-rig.webp'),save_all=True,append_images=frames[1:],duration=40,loop=0,quality=95,method=1,alpha_quality=100)
 contact=Image.new('RGB',(1536,256),'#f4f3ea')
 for j,n in enumerate([0,30,55,75,105,135]):
  bg=Image.new('RGBA',(512,512),'#f4f3ea');bg.alpha_composite(frames[n]);contact.paste(bg.resize((256,256)).convert('RGB'),(j*256,0))
 contact.save(ROOT/(stem+'-rig-contact.jpg'),quality=90)
 print(stem+' articulated preview ready',flush=True)
 return frames
if __name__=='__main__':
 for stem in ['cat-morning','cat-laugh','cat-flower','cat-victory']:build(stem)
 print('Four articulated test animations; full 72-item revision remains in progress')
