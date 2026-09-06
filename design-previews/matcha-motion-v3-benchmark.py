from pathlib import Path
from PIL import Image,_webp
import time
root=Path('D:/projects/cubechat/design-previews/matcha-motion-v3')
root.mkdir(exist_ok=True)
src=Image.open('D:/projects/cubechat/design-previews/matcha-motion-v2/cat-wave.webp')
enc=_webp.WebPAnimEncoder((2048,2048),0,0,False,3,5,False,False)
start=time.time()
for i in range(20):
 src.seek(i);frame=src.convert('RGBA').resize((2048,2048),Image.Resampling.LANCZOS)
 enc.add(frame.getim(),i*40,False,92,100,0)
enc.add(None,800,False,92,100,0)
data=enc.assemble('','','')
(root/'encoding-sample.webp').write_bytes(data)
print({'frames':20,'seconds':round(time.time()-start,2),'bytes':len(data)})

