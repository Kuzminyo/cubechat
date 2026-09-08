from pathlib import Path
import json,re,shutil
root=Path('D:/projects/cubechat/design-previews');dest=root/'matcha-motion-v7';q=root/'motion-quality'
html=(root/'matcha-motion-v6/index.html').read_text(encoding='utf-8')
html=html.replace('ВЕРСИЯ 06','ВЕРСИЯ 07').replace('4 нарисованные позы','Движение отдельными деталями').replace('matcha-motion-revised-72.zip','matcha-motion-v7-72.zip').replace('Жесты и мимика по примеру первых анимаций.','Знакомые эмоции, мягкие жесты и спокойные паузы.')
# Start with stills; animate only the images actually visible in the gallery.
html=re.sub(r'(src="(?:cat|emoji)-[a-z]+)\.webp"',r'\1.png"',html)
html=html.replace('for(const img of pictures)observer.observe(img);','for(const img of pictures)observer.observe(img);\ndocument.addEventListener("visibilitychange",()=>{for(const img of pictures)paint(img);if(document.hidden)hdVideo.pause()});')
html=html.replace("const suffix=paused||!visible.has(img)?", "const suffix=paused||document.hidden||!visible.has(img)?")
html=html.replace('для лёгкого просмотра есть WebP и GIF.','для лёгкого просмотра есть прозрачный WebP и GIF на светлом фоне.')
(dest/'index.html').write_text(html,encoding='utf-8')
css=html.split('<style>')[1].split('</style>')[0]
compare='<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Движение: сравнение версий</title><style>'+css+'.pair{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:16px 0 32px}.pair img{width:100%;max-width:300px}.pair figure{margin:0;text-align:center;background:var(--panel);border-radius:24px;padding:18px}.pair figcaption{color:var(--muted);font-size:14px}</style><main><header><div><div class="eyebrow">CUBECHAT · СРАВНЕНИЕ</div><h1>Движения котика</h1><p>Четыре сюжета из присланного видео.</p></div><a class="pill" href="index.html">Все 72</a></header>'
for stem,label in [('cat-laugh','Смех'),('cat-morning','Доброе утро'),('cat-flower','Это тебе'),('cat-victory','Победа!')]:
 compare+='<h2>'+label+'</h2><div class="pair"><figure><img src="../matcha-motion-v6/'+stem+'.webp" alt="Предыдущая версия"><figcaption>Версия 06</figcaption></figure><figure><img src="'+stem+'.webp" alt="Новая версия"><figcaption>Версия 07</figcaption></figure></div>'
compare+='<a class="pill" href="../matcha-motion/index.html">Самые первые 8</a></main></html>'
(dest/'compare.html').write_text(compare,encoding='utf-8')
readme='''# Matcha & Emoji · версия 07

72 макета: 36 котиков и 36 эмодзи. Откройте index.html в браузере.
Нажмите на карточку для крупного просмотра и скачивания отдельного файла.
Есть пауза, тёмный фон и просмотр видео 2048 × 2048.

Движение пересобрано из отдельных деталей. Форма головы и корпуса не
интерполируется между независимо нарисованными позами. Жесты используют
привязанные лапы, предметы, повороты деталей и мимику с паузами.
Набор остаётся дизайн-макетом для выбора и последующей интеграции.
Слои перерисованы с опорой на прежний стиль и палитру, поэтому это не
пиксельно неизменённые исходные рисунки. Сон, усталость, бег, сердце,
огонь и одобрение сохраняют исходные рисунки.

Форматы:
- WebP: прозрачная анимация 512 × 512, цикл 6 секунд, 25 кадров/с.
- PNG: стоп-кадр 512 × 512.
- png-2k/: прозрачный PNG 2048 × 2048.
- webm-2k/: прозрачный VP9 WebM 2048 × 2048, цикл 6 секунд.
- GIF: 256 × 256 на светлом фоне, цикл 6 секунд.

2K — увеличенный экспорт исходников меньшего разрешения, не нативная
детализация 2K. Это не Telegram TGS и не готовая интеграция во Flutter.

Источники графики: встроенный ImageGen, описание задания в prompts.json,
листы деталей в sources/. Скрипты сборки и проверки находятся рядом,
в ../motion-quality/: build-cat-rig.py, build-emoji-rig.py,
export-collection.py, check-collection.py. Все ресурсы хранятся в проекте.
compare.html показывает версию 06, когда обе папки лежат рядом.
'''
(dest/'README.md').write_text(readme,encoding='utf-8')
(dest/'prompts.json').write_text(json.dumps({'tool':'built-in ImageGen','references':'previous approved matcha cat and classic golden emoji sheets','emoji_base':'High-resolution blank glossy golden yellow circular emoji sphere, no features, isolated on flat magenta.','emoji_features':'Strict 4x4 isolated facial sprite parts: open, happy, angry, white and pleading eyes; smile, laugh, O, frown, flat, kiss, grin, tongue mouth, raised/worried brows, glasses. Same classic emoji rendering.','emoji_props':'Strict 4x4 isolated gold hands and emoji props: open, clap, shush, salute, think, cover, prayer, approve; tear, heart, star, halo, zipper, party hat, blower, explosion. Solid magenta background.','cat_rig':'Muted matcha cat matching references; separate stable core, arms, tail, eyes, mouths, flower, trophy, tears, sparkle. Fixed drawing; no pose morphing.','cat_props':'Strict 5x4 sprite sheet, 20 isolated illustrated props with dark olive outlines and cream/matcha palette: heart pillow, matcha cup, sunglasses, hourglass, blanket, cookie, laptop, cake, headphones, controller, umbrella, box, coral/cream pompoms, scarf, popcorn, party hat, bandage, tail, cushion. No cats, hands or text.','background_edit':'Keep every object, shape, color and position unchanged. Replace the checkerboard with uniform flat magenta RGB 255,0,255, including all holes, without changing cream surfaces.','motion':'Rigid anchored parts, eased 6-second loops at 25fps. No optical flow or whole-drawing mesh deformation.','resolution':'512-pixel working render; 2048-pixel upscaled PNG and VP9 WebM.'},ensure_ascii=False,indent=2),encoding='utf-8')
# The locally saved rig sheet is authoritative; generation cache is only a first-run fallback.
p=q/'build-rig-prototype.py';s=p.read_text(encoding='utf-8');s=s.replace("shutil.copy2(SRC,ROOT/'rig-sheet.png')\nsheet=Image.open(SRC)","if not (ROOT/'rig-sheet.png').exists():shutil.copy2(SRC,ROOT/'rig-sheet.png')\nsheet=Image.open(ROOT/'rig-sheet.png')");p.write_text(s,encoding='utf-8')
print('Version 07 gallery, comparison, source descriptions and README saved')
