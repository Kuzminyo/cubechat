from pathlib import Path
import json,re,shutil
root=Path('D:/projects/cubechat/design-previews/matcha-motion-v6')
base=root.parent/'matcha-motion-v3'
items=json.loads((root/'manifest.json').read_text(encoding='utf-8'))
html=(base/'index.html').read_text(encoding='utf-8-sig')
for kind,title in [('cat','cats-title'),('emoji','emoji-title')]:
 cards=''.join('<button class="card '+x['kind']+'" data-open="'+x['id']+'" data-label="'+x['label']+'"><img data-base="'+x['id']+'" src="'+x['id']+'.webp" alt="'+x['label']+'" loading="lazy"><span>'+x['label']+'</span></button>' for x in items if x['kind']==kind)
 pattern=r'(<section aria-labelledby="'+title+r'">[\s\S]*?<div class="grid">)[\s\S]*?(</div></section>)'
 html=re.sub(pattern,lambda m:m.group(1)+cards+m.group(2),html)
html=html.replace('КОЛЛЕКЦИЯ 03 · 2K','ДВИЖЕНИЯ · ВЕРСИЯ 06').replace('40 эмоций в спокойном ритме.','Жесты и мимика по примеру первых анимаций.').replace('40 анимаций','72 анимации').replace('20 стикеров','36 стикеров').replace('20 реакций','36 реакций').replace('Циклы по 4 секунды.','Циклы по 6 секунд, с паузами между жестами.').replace('Плавные переходы','4 нарисованные позы').replace('лёгкое движение','выразительная мимика').replace('matcha-2k-pack-v3.zip','matcha-motion-revised-72.zip')
html=html.replace('<button class="pill" id="pause"','<a class="pill" href="compare.html">Сравнить движения</a><button class="pill" id="pause"')
html=html.replace('href="../matcha-motion-v2/index.html">Коллекция 02','href="../matcha-motion/index.html">Самые первые 8')
(root/'index.html').write_text(html,encoding='utf-8')
css=html.split('<style>')[1].split('</style>')[0]
compare='<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Сравнение движений</title><style>'+css+'.comparison{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:16px 0 32px}.comparison img{width:100%;max-width:300px}.comparison figure{margin:0;text-align:center;background:var(--panel);border-radius:24px;padding:18px}.comparison figcaption{color:var(--muted);font-size:14px}</style><main><header><div><div class="eyebrow">MATCHA & EMOJI · ДВИЖЕНИЯ</div><h1>Больше жизни</h1><p>В предыдущем варианте двигалась одна поза. Теперь меняются жесты и выражение лица.</p></div><a class="pill" href="index.html">Все 72</a></header>'
for stem in ['cat-wave','cat-thanks','cat-peek','emoji-wink','emoji-sleepy','emoji-salute']:
 label=next(x['label'] for x in items if x['id']==stem)
 compare+='<h2>'+label+'</h2><div class="comparison"><figure><img src="../matcha-motion-v5/'+stem+'.webp" alt="Предыдущие движения"><figcaption>Было · одна поза</figcaption></figure><figure><img src="'+stem+'.webp" alt="Исправленные движения"><figcaption>Теперь · жесты и мимика</figcaption></figure></div>'
compare+='<a class="pill" href="../matcha-motion/index.html">Первые 8 — образец движения</a></main></html>'
(root/'compare.html').write_text(compare,encoding='utf-8')
shutil.copy2(root.parent/'matcha-motion-v5'/'serve.py',root/'serve.py')
export=(root.parent/'matcha-motion-v5'/'export-2k.py').read_text(encoding='utf-8-sig')
export=export.replace("items=[x for x in json.loads((root/'manifest.json').read_text(encoding='utf-8')) if x.get('added_in')=='05']","items=json.loads((root/'manifest.json').read_text(encoding='utf-8'))")
export=export.replace('count==100','count==150').replace("'cycle_ms':4000","'cycle_ms':6000")
export=re.sub(r"start=time.time\(\);result=json.loads\([^\n]+",'start=time.time();result=[]',export)
(root/'export-2k.py').write_text(export,encoding='utf-8')
script=(root/'build-motion.py').read_text(encoding='utf-8-sig')
script=script.replace("selected=all_poses if '--sample' not in sys.argv else", "selected={s:p for s,p in all_poses.items() if not (ROOT/(s+'.webp')).exists()} if '--sample' not in sys.argv else")
(root/'build-motion.py').write_text(script,encoding='utf-8')
readme='''# Matcha & Emoji — motion revision 06
72 revised action animations (36 cats + 36 emoji). This revision responds to the
request to follow the FIRST eight animations: distinct drawn action poses and
facial changes, rather than small idle deformation of one still.

The first 24 use their original four-pose sheets. For the remaining 48, ImageGen
created extra poses using the existing sticker art as reference. Their visual
design is retained as the reference; small drawing variations across poses remain.
Approved static PNGs and 2K still exports are copied unchanged from collection 05.

Each 6-second loop has expression holds and eased single-source optical-flow
inbetweens at 25 fps. The source switches between drawn poses; these are animated
concept studies, not hand-cleaned production animation or Telegram TGS files.
WebP is 512 x 512, GIF is 240 x 240 on ivory. Transparent VP9 WebM is 2048 x 2048.
The 2K files are upscaled exports from smaller drawings, not native 2K detail.

Open index.html for the collection. compare.html shows previous/revised motion
while served alongside the earlier collections. No Flutter integration.
The built-in ImageGen tool produced pose sheets; build-motion.py records the
source mapping, framing, background keying and motion timing. All source sheets
and 288 individual poses are retained in the workspace.
'''
(root/'README.md').write_text(readme,encoding='utf-8')
(root/'prompts.json').write_text(json.dumps({'purpose':'Restore initial four-pose action animation, preserve the visual designs referenced in references/.','tool':'built-in ImageGen','source_map':json.loads((root/'batches.json').read_text(encoding='utf-8')),'pose_spec':'Four consecutive poses per action; prepare, gesture, expression, release. Same palette, character, props and rendering as original reference.','timing':'6 seconds; 150 samples; eased interpolation and expression holds; no opacity crossfades','quality':'2K upscaled export, not native 2K detail'},ensure_ascii=False,indent=2),encoding='utf-8')
print('72-card revised preview prepared')
