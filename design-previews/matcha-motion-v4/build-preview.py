from pathlib import Path
import json,re
root=Path(__file__).resolve().parent
base=root.parent/'matcha-motion-v3'
items=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
def cards(group):
 group=sorted(group,key=lambda x:x.get('added_in')!='04')
 return ''.join('<button class="card '+x['kind']+'" data-new="'+str(x.get('added_in')=='04').lower()+'" data-open="'+x['id']+'" data-label="'+x['label']+'"><img data-base="'+x['id']+'" src="'+x['id']+'.webp" alt="'+x['label']+'" loading="lazy"><span>'+x['label']+'</span></button>' for x in group)
html=(base/'index.html').read_text(encoding='utf-8-sig')
for kind,title in [('cat','cats-title'),('emoji','emoji-title')]:
 pattern=r'(<section aria-labelledby="'+title+r'">[\s\S]*?<div class="grid">)[\s\S]*?(</div></section>)'
 html=re.sub(pattern,lambda m:m.group(1)+cards([x for x in items if x['kind']==kind])+m.group(2),html)
html=html.replace('КОЛЛЕКЦИЯ 03 · 2K','КОЛЛЕКЦИЯ 04 · 2K').replace('40 анимаций','56 анимаций').replace('40 эмоций в спокойном ритме.','Ещё 16 эмоций. Всего — 56.').replace('20 стикеров','28 стикеров').replace('20 реакций','28 реакций')
html=html.replace('matcha-2k-pack-v3.zip','matcha-new-16-v4.zip').replace('Скачать набор','Скачать новые 16')
html=html.replace('<button class="pill" id="pause"','<button class="pill" id="filter-new" aria-pressed="false">Только новые</button><button class="pill" id="pause"')
html=html.replace('<style>','<style>body.new-only .card[data-new="false"]{display:none}')
html=html.replace('href="../matcha-motion-v2/index.html">Коллекция 02','href="../matcha-motion-v3/index.html">Предыдущие 40')
html=html.replace('sync();\n</script>',"""document.getElementById('filter-new').onclick=e=>{const on=document.body.classList.toggle('new-only');e.currentTarget.setAttribute('aria-pressed',String(on));e.currentTarget.textContent=on?'Показать все 56':'Только новые';document.querySelectorAll('.count').forEach((n,i)=>n.textContent=(on?'8':'28')+(i===0?' стикеров':' реакций'))};
sync();
</script>""")
(root/'index.html').write_text(html,encoding='utf-8')
readme="""# Matcha & Emoji — Collection 04
16 new animated designs: 8 matcha cats and 8 classic emoji.
The live collection now contains 56 designs (28 cats, 28 emoji).
The downloadable expansion ZIP contains only these 16 new designs.

Cat: morning stretch, cozy blanket, flower, cookie, work, hurry, birthday, nope.
Emoji: grin, rolling laughter, tongue, relieved, skeptical, unamused, pleading,
starstruck.

Each loop lasts 4 seconds at 25 fps. Continuous gentle local motion preserves
the drawing without crossfading between different poses.
PNG and transparent VP9 WebM exports are 2048 x 2048. These are upscaled exports
from smaller generated artwork, not native 2K redrawing.
WebP previews are 512 x 512; GIF previews are 240 x 240 on an ivory background.
ImageGen created the new artwork. prompts.json records the prompts.
This is a visual concept collection, not a Flutter integration.

Open index.html for the new collection. 2K video works best in a browser that
supports VP9 transparency. The Codex preview has been checked in Chromium.
"""
(root/'README.md').write_text(readme,encoding='utf-8')
serve="""from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import json,os
root=Path(__file__).resolve().parent
server=ThreadingHTTPServer(('127.0.0.1',0),partial(SimpleHTTPRequestHandler,directory=str(root.parent)))
(root/'preview-server.json').write_text(json.dumps({'pid':os.getpid(),'url':'http://127.0.0.1:'+str(server.server_address[1])+'/'+root.name+'/'}),encoding='utf-8')
server.serve_forever()
"""
(root/'serve.py').write_text(serve,encoding='utf-8')
print('56-card preview ready')

