from pathlib import Path
import shutil,json
r=Path('D:/projects/cubechat/design-previews');q=r/'motion-quality';v=r/'matcha-motion-v7'
(v/'reference').mkdir(exist_ok=True)
for stem in ['cat-laugh','cat-morning','cat-flower','cat-victory']:shutil.copy2(r/'matcha-motion-v6'/(stem+'.webp'),v/'reference'/('previous-'+stem+'.webp'))
first=['cat-wave','cat-laugh','cat-love','cat-sleep','emoji-smile','emoji-laugh','emoji-heart','emoji-kiss']
for stem in first:shutil.copy2(r/'matcha-motion'/(stem+'.webp'),v/'reference'/('first-'+stem+'.webp'))
for filename in ['index.html','compare.html']:
 p=v/filename;s=p.read_text(encoding='utf-8').replace('../matcha-motion/index.html','first-eight.html').replace('../matcha-motion-v6/','reference/previous-');p.write_text(s,encoding='utf-8')
css=(v/'index.html').read_text(encoding='utf-8').split('<style>')[1].split('</style>')[0]
page='<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Первые 8 — образец движений</title><style>'+css+'</style><main><div class="eyebrow">ИСХОДНЫЙ ОБРАЗЕЦ</div><h1>Самые первые 8</h1><p>Исходная скорость и рисунки сохранены для сравнения.</p><a class="pill" href="index.html">Новая коллекция</a><div class="grid" style="margin-top:24px">'
labels={x['id']:x['label'] for x in json.loads((v/'manifest.json').read_text(encoding='utf-8'))}
for stem in first:page+='<div class="card"><img src="reference/first-'+stem+'.webp" alt="'+labels[stem]+'"><span>'+labels[stem]+'</span></div>'
page+='</div></main></html>';(v/'first-eight.html').write_text(page,encoding='utf-8')
for folder in ['parts','cat-props','emoji-parts']:
 shutil.copytree(q/folder,v/'sources'/folder,dirs_exist_ok=True)
(v/'sources/originals').mkdir(exist_ok=True)
for stem in ['cat-sleep','cat-tired','cat-hurry','emoji-heart','emoji-fire','emoji-approve']:shutil.copy2(r/'matcha-motion-v6/masters'/(stem+'.png'),v/'sources/originals'/(stem+'.png'))
p=v/'README.md';s=p.read_text(encoding='utf-8').replace('compare.html показывает версию 06, когда обе папки лежат рядом.','compare.html и first-eight.html содержат локальные копии образцов для сравнения.\nАрхив открывается самостоятельно, без соседних папок.');p.write_text(s,encoding='utf-8')
print('Self-contained comparisons and source layers copied')
