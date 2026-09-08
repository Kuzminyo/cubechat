from pathlib import Path
import json,sys
from PIL import Image,ImageDraw
r=Path('D:/projects/cubechat/design-previews/matcha-motion-v8');items=json.loads((r/'manifest.json').read_text(encoding='utf-8'));pending=[x for x in items if x['id']!='cat-shy'];groups=[pending[i:i+4] for i in range(0,len(pending),4)];n=int(sys.argv[1]) if len(sys.argv)>1 else 0
rows=groups[n];out=Image.new('RGB',(1040,270*len(rows)),'#f4f3ea');d=ImageDraw.Draw(out)
for row,item in enumerate(rows):
 d.text((12,row*270+5),'REFERENCE ROW '+str(row+1)+' / '+item['id'],fill='#30382a')
 for col in range(4):
  im=Image.open(r/'original-poses'/(item['id']+'-'+str(col)+'.png')).convert('RGBA');im.thumbnail((245,235));out.paste(im,(col*260+(260-im.width)//2,row*270+28),im)
p=r/('reference-batch-'+str(n)+'.jpg');out.save(p,quality=92)
meta={'batch':n,'total_batches':len(groups),'reference':str(p),'items':[{'id':x['id'],'label':x['label'],'kind':x['kind'],'reference_row':i+1} for i,x in enumerate(rows)]};(r/'active-batch.json').write_text(json.dumps(meta,ensure_ascii=False),encoding='utf-8');print(json.dumps(meta,ensure_ascii=False))
