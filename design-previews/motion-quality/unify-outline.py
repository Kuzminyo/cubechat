from pathlib import Path
p=Path('D:/projects/cubechat/design-previews/motion-quality/build-rig-prototype.py');s=p.read_text(encoding='utf-8-sig')
s=s.replace("im=key(sheet.crop(tuple(round(v*(W if i%2==0 else H)) for i,v in enumerate(rect))))", """im=key(sheet.crop(tuple(round(v*(W if i%2==0 else H)) for i,v in enumerate(rect))))
 # Strip only the white edging connected to the outside. Internal eye highlights remain.
 pixels=np.array(im);rgb=pixels[:,:,:3].astype(float)
 eligible=(pixels[:,:,3]<32)|((rgb.min(2)>195)&((rgb.max(2)-rgb.min(2))<45))
 _,labels=cv2.connectedComponents(eligible.astype(np.uint8),4)
 outside=set(labels[0])|set(labels[-1])|set(labels[:,0])|set(labels[:,-1]);outside.discard(0)
 strip=np.isin(labels,list(outside));pixels[strip,3]=0
 im=Image.fromarray(pixels)""")
s=s.replace("if tilt:frame=frame.rotate(tilt,resample=Image.Resampling.BICUBIC,center=(256,416))\n return frame", """if tilt:frame=frame.rotate(tilt,resample=Image.Resampling.BICUBIC,center=(256,416))
 # The sticker has one outer outline, not white seams around overlapping body parts.
 outline=Image.new('RGBA',frame.size,(255,255,250,0))
 outline.putalpha(frame.getchannel('A').filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.GaussianBlur(.3)))
 outline.alpha_composite(frame)
 return outline""")
p.write_text(s,encoding='utf-8')
