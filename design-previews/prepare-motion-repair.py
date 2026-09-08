from pathlib import Path
from PIL import Image,ImageOps,ImageDraw
import json
base=Path('D:/projects/cubechat/design-previews/matcha-motion-v5')
root=base.parent/'matcha-motion-v6'
root.mkdir(exist_ok=True)
(root/'references').mkdir(exist_ok=True)
items=json.loads((base/'manifest.json').read_text(encoding='utf-8'))
batches=[]
for kind in ['cat','emoji']:
 new=[x for x in items if x['kind']==kind and x.get('added_in')!='02']
 for offset in range(0,len(new),6):
  group=new[offset:offset+6];sheet=Image.new('RGB',(900,1350),'#f4f3ea');draw=ImageDraw.Draw(sheet)
  for n,item in enumerate(group):
   im=Image.open(base/'masters'/(item['id']+'.png')).convert('RGBA')
   im=ImageOps.contain(im,(420,400));x=(n%2)*450+(450-im.width)//2;y=(n//2)*450
   sheet.paste(im,(x,y),im);draw.text(((n%2)*450+20,y+413),str(n+1)+' '+item['id'],fill='#253322')
  name=kind+'-'+str(offset//6+1);sheet.save(root/'references'/(name+'.jpg'),quality=92)
  batches.append({'name':name,'items':group})
(root/'batches.json').write_text(json.dumps(batches,ensure_ascii=False,indent=2),encoding='utf-8')
print([(b['name'],[x['id'] for x in b['items']]) for b in batches])
