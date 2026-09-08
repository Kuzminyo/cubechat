from pathlib import Path
r=Path('D:/projects/cubechat/design-previews/motion-quality');p=r/'build-rig-prototype.py';s=p.read_text(encoding='utf-8-sig')
s=s.replace("eyes_open=fit('eyes-open',w=153);eyes_closed=fit('eyes-closed',w=153)","eyes_open=fit('eyes-open',w=168);eyes_closed=fit('eyes-closed',w=168)")
s=s.replace('lossless=True,method=2','quality=95,method=1,alpha_quality=100')
s=s.replace("if stem=='cat-flower':arms=(29+12*gesture,-29-12*gesture);prop=flower;raise_prop=35*gesture;eye_happy=gesture;smile=.1", "if stem=='cat-flower':arms=(29,-29);prop=flower;raise_prop=66*gesture;eye_happy=gesture;smile=0")
s=s.replace("if stem=='cat-victory':arms=(33+10*gesture,-33-10*gesture);prop=trophy;raise_prop=27*gesture;eye_happy=gesture;smile=gesture*.7", "if stem=='cat-victory':arms=(33,-33);prop=trophy;raise_prop=27*gesture;eye_happy=gesture;smile=gesture*.7")
s=s.replace('def render(stem,fi):', '''def ik_arm(im,shoulder,target,side):
 # Two rigid segments share an elbow. The endpoint is fixed to the prop's grip.
 origin=np.array(shoulder,dtype=float);goal=np.array(target,dtype=float)
 axis=goal-origin;distance=float(np.linalg.norm(axis));l1=64.;l2=48.
 distance=min(l1+l2-.1,max(abs(l1-l2)+.1,distance));u=axis/np.linalg.norm(axis)
 a=(l1*l1-l2*l2+distance*distance)/(2*distance);height=math.sqrt(max(0,l1*l1-a*a))
 perp=np.array([-u[1],u[0]])*(-side);elbow=origin+u*a+perp*height
 upper=im.crop((0,0,im.width,99));lower=im.crop((0,64,im.width,im.height))
 def angle(v):return -math.degrees(math.atan2(v[0],v[1]))
 proximal=layer(upper,tuple(origin),(im.width*.5,15),angle(elbow-origin))
 distal_layer=layer(lower,tuple(elbow),(im.width*.5,15),angle(goal-elbow))
 paw=lower.copy();alpha=np.array(paw.getchannel('A')).astype(float);ramp=np.clip((np.arange(paw.height)-35)/12,0,1)
 paw.putalpha(Image.fromarray(np.uint8(alpha*ramp[:,None])))
 hand=layer(paw,tuple(elbow),(im.width*.5,15),angle(goal-elbow))
 return proximal,distal_layer,hand

def render(stem,fi):''')
s=s.replace("frame.alpha_composite(layer(left,shoulder_l,pivot_l,arms[0]));frame.alpha_composite(layer(right,shoulder_r,pivot_r,arms[1]))", """rigged=None
 if prop:
  py=364-raise_prop
  grips=((243,py+35),(269,py+35)) if stem=='cat-flower' else ((216,py-10),(296,py-10))
  rigged=[ik_arm(left,shoulder_l,grips[0],-1),ik_arm(right,shoulder_r,grips[1],1)]
  for upper,forearm,hand in rigged:frame.alpha_composite(upper)
 else:
  frame.alpha_composite(layer(left,shoulder_l,pivot_l,arms[0]));frame.alpha_composite(layer(right,shoulder_r,pivot_r,arms[1]))""")
s=s.replace("paste(frame,core,(256,251))", """paste(frame,core,(256,251))
 blush=Image.new('RGBA',(SIZE,SIZE));brush=ImageDraw.Draw(blush)
 for bx in [181,331]:brush.ellipse((bx-18,233,bx+18,253),fill=(233,130,118,70))
 frame.alpha_composite(blush.filter(ImageFilter.GaussianBlur(6)))""")
s=s.replace("if prop:paste(frame,prop,(256,364-raise_prop))\n frame.alpha_composite(layer(lf,shoulder_l,pivot_l,arms[0]));frame.alpha_composite(layer(rf,shoulder_r,pivot_r,arms[1]))", """if prop:
  for upper,forearm,hand in rigged:frame.alpha_composite(forearm)
  paste(frame,prop,(256,364-raise_prop))
  for upper,forearm,hand in rigged:frame.alpha_composite(hand)
 else:
  frame.alpha_composite(layer(lf,shoulder_l,pivot_l,arms[0]));frame.alpha_composite(layer(rf,shoulder_r,pivot_r,arms[1]))""")
p.write_text(s,encoding='utf-8')
