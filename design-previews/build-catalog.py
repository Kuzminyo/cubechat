from pathlib import Path
import shutil,json,html
root=Path('D:/projects/cubechat/design-previews')
source=Path('C:/Users/kuzme/.codex/generated_images/01a07721-3949-7910-9e64-eaae4d5bf0e0')
art=root/'source-art';art.mkdir(exist_ok=True)
for p in sorted(source.glob('*.png')):shutil.copy2(p,art/p.name)
style='''*{box-sizing:border-box}body{margin:0;background:#f4f3ea;color:#30382a;font:16px/1.55 system-ui,sans-serif}main{max-width:1080px;margin:auto;padding:46px 24px 70px}h1{font-size:42px;letter-spacing:-.04em;margin:7px 0 10px;font-weight:600}h2{font-size:23px;margin:30px 0 12px}p{color:#707961}.eyebrow{font-size:12px;color:#65734d;letter-spacing:.13em}.links{display:flex;flex-wrap:wrap;gap:10px;margin:22px 0}.links a{border:1px solid #cbd2bd;border-radius:28px;padding:11px 18px;color:inherit;text-decoration:none}.links a.primary{background:#30382a;color:#f4f3ea}.preview{display:grid;grid-template-columns:repeat(4,1fr);gap:14px}.preview img{width:100%;border-radius:22px;background:#ffffff70}.versions{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.versions a{padding:20px;color:inherit;text-decoration:none;border:1px solid #dce0ce;border-radius:20px;background:#ffffff60}.versions b,.versions span{display:block}.versions span{color:#707961;font-size:14px;margin-top:8px}a:focus-visible{outline:3px solid #939b78;outline-offset:3px}.note{font-size:13px;max-width:800px;margin-top:28px}.art{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}.art img{width:100%;height:300px;object-fit:contain;background:white}.art a{color:inherit;font-size:12px;overflow-wrap:anywhere}@media(max-width:650px){main{padding:26px 16px}.versions,.art{grid-template-columns:1fr 1fr}.preview{grid-template-columns:1fr 1fr}h1{font-size:33px}}'''
versions=[('matcha-motion','Первые 8','Исходный пример движений'),('matcha-motion-v2','Коллекция 02 · 24','Первая расширенная коллекция'),('matcha-motion-v3','Коллекция 03 · 40','Добавлен экспорт 2K'),('matcha-motion-v4','Коллекция 04 · 56','Ещё 16 реакций'),('matcha-motion-v5','Коллекция 05 · 72','Версия до исправления движений'),('matcha-motion-v6','Исходные рисунки · 72','Прежние котики и эмодзи — основа доработки'),('matcha-motion-v7','Архив версии 07','Вариант с отдельными деталями'),('matcha-motion-v8','Прежние рисунки + кадры','Дополнительные нарисованные позы')]
page='<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CubeChat — все макеты стикеров</title><style>'+style+'</style><main><div class="eyebrow">CUBECHAT · СТИКЕРЫ И ЭМОДЗИ</div><h1>Все макеты в одном месте</h1><p>Котик матча и классические эмодзи. Вернулись к прежним рисункам. Добавляем между исходными позами новые нарисованные кадры.</p><div class="links"><a class="primary" href="matcha-motion-v8/index.html">Старые стикеры с новыми кадрами</a><a href="matcha-motion-v6/index.html">Исходная коллекция</a></div><div class="preview">'
for stem in ['cat-wave','cat-love','cat-shy','cat-matcha']:page+='<img src="matcha-motion-v8/'+stem+'.webp" alt="Пример анимации">'
page+='</div><h2>Все версии</h2><div class="versions">'
for folder,title,desc in versions:page+='<a href="'+folder+'/index.html"><b>'+title+'</b><span>'+desc+'</span></a>'
page+='</div><h2>Исходные рисунки</h2><p>Все 23 листа и варианта, включая промежуточные макеты.</p><div class="links"><a href="source-art/index.html">Посмотреть исходники</a></div><p class="note">Все изображения, анимации и страницы сохранены внутри design-previews. Для просмотра достаточно открыть этот файл в браузере. 2K — размер экспорта 2048 × 2048; исходные рисунки увеличены из меньшего разрешения.</p></main></html>'
page=page.replace('Все 23 листа и варианта','Все '+str(len(list(art.glob('*.png'))))+' листов и вариантов')
(root/'index.html').write_text(page,encoding='utf-8')
page='<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Исходные рисунки стикеров</title><style>'+style+'</style><main><div class="eyebrow">CUBECHAT · ИСХОДНИКИ</div><h1>Листы и варианты</h1><p>Все изображения из этой работы. Здесь есть промежуточные варианты и технические листы фаз движения.</p><div class="links"><a href="../index.html">Все макеты</a></div><div class="art">'
for i,p in enumerate(sorted(art.glob('*.png')),1):page+='<a href="'+p.name+'"><img loading="lazy" src="'+p.name+'" alt="Исходный лист '+str(i)+'"><p>Лист '+str(i)+' · '+p.name+'</p></a>'
page+='</div></main></html>';(art/'index.html').write_text(page,encoding='utf-8')
(root/'README.md').write_text("""# Макеты стикеров и эмодзи CubeChat

Общий каталог: index.html.
Текущая доработка: matcha-motion-v8/index.html — исходные рисунки версии 06
с добавленными нарисованными промежуточными позами. Прогресс указан в галерее.
Все 288 исходных ключевых рисунков сохранены без изменений.
Исходная коллекция: matcha-motion-v6/index.html.
Версия 07 с отдельными деталями оставлена в архиве, её доработка прекращена.
Все исходные листы: source-art/index.html.

2K означает размер экспорта, а не исходную детализацию рисунков.
Макеты пока не встроены во Flutter-приложение.
""",encoding='utf-8')
print(json.dumps({'catalog':str(root/'index.html'),'source_art_copied':len(list(art.glob('*.png'))),'versions':len(versions)},ensure_ascii=False))
