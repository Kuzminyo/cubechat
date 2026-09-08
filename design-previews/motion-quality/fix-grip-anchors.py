from pathlib import Path
p=Path('D:/projects/cubechat/design-previews/motion-quality/build-rig-prototype.py');s=p.read_text(encoding='utf-8-sig')
s=s.replace("axis=goal-origin;distance=float(np.linalg.norm(axis));l1=64.;l2=48.","""pixels=np.array(im);pink=(pixels[:,:,3]>180)&(pixels[:,:,0].astype(float)-pixels[:,:,1]>40)&(pixels[:,:,0].astype(float)-pixels[:,:,2]>50)
  # Measured pad center is the grip anchor; don't assume the crop center is the hand.
 ys,xs=np.where(pink & (np.arange(im.height)[:,None]>im.height*.65))
 palm=np.array([float(xs.mean()),float(ys.mean())]) if len(xs) else np.array([im.width*.55,im.height*.84])
 native=palm-np.array([im.width*.5,79.])
 axis=goal-origin;distance=float(np.linalg.norm(axis));l1=64.;l2=float(np.linalg.norm(native))""")
s=s.replace('def angle(v):return -math.degrees(math.atan2(v[0],v[1]))','def angle(v):return math.degrees(math.atan2(v[0],v[1]))')
s=s.replace('angle(goal-elbow))','angle(goal-elbow)-angle(native))')
s=s.replace('b=max(blink(t),eye_happy)\n if b>.88:', 'b=blink(t)\n if eye_happy>.45 or b>.88:')
p.write_text(s,encoding='utf-8')
