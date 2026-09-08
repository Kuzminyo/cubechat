from pathlib import Path
import json,hashlib
r=Path('D:/projects/cubechat/design-previews');v=r/'matcha-motion-v8'
items=json.loads((v/'manifest.json').read_text(encoding='utf-8'));done=[x for x in items if x['revision_status']=='inbetweens_added']
css=(r/'matcha-motion-v6/index.html').read_text(encoding='utf-8').split('<style>')[1].split('</style>')[0]
page='<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Старые стикеры · дополнительные кадры</title><style>'+css+'</style><main><div class="eyebrow">CUBECHAT · ИСХОДНЫЙ РИСУНОК</div><h1>Тот самый котик</h1><p>Сохраняем прежние рисунки и дополняем переходы нарисованными промежуточными позами.</p><div class="tags"><span>'+str(len(done))+' из 72 дополнены</span><span>Исходные кадры сохранены</span><span>Покадровая анимация</span></div><div class="controls"><button class="pill" id="pause">Пауза</button><button class="pill" id="theme">Тёмный фон</button><a class="pill" href="original-cycles/index.html">Вся прежняя коллекция</a></div>'
for kind,title in [('cat','Котик матча'),('emoji','Эмодзи')]:
 page+='<h2 style="margin-top:32px">'+title+'</h2><div class="grid">'
 for item in items:
  if item['kind']!=kind:continue
  is_done=item['revision_status']=='inbetweens_added';base=('' if is_done else '../matcha-motion-v6/')+item['id']
  page+='<button class="card" data-base="'+base+'" data-label="'+item['label']+'"><img data-base="'+base+'" src="'+base+'.webp" loading="lazy" alt="'+item['label']+'"><span>'+item['label']+(' · '+str(item['drawn_frames'])+' кадров' if is_done else ' · исходный цикл')+'</span></button>'
 page+='</div>'
page+='<p style="font-size:13px;margin-top:32px">2K — размер экспорта 2048 × 2048. Исходные рисунки увеличены из меньшего разрешения.</p><a class="pill" href="matcha-motion-v8-72.zip" download>Скачать всю коллекцию</a></main><dialog id="detail"><div class="dialog-top"><h2 id="title"></h2><button class="close" aria-label="Закрыть">×</button></div><img class="zoom" id="zoom" alt=""><div class="formats"><a class="pill" id="download" download>WebP</a><a class="pill" id="gif" download>GIF</a><a class="pill" id="png2k" target="_blank">PNG 2K</a><a class="pill" id="webm2k" target="_blank">Анимация 2K</a><a class="pill" id="poses" target="_blank">Кадры</a></div></dialog><script>let paused=false;const dialog=document.getElementById("detail");document.getElementById("pause").onclick=e=>{paused=!paused;document.querySelectorAll("img[data-base]").forEach(im=>im.src=im.dataset.base+(paused?".png":".webp"));e.currentTarget.textContent=paused?"Продолжить":"Пауза"};document.getElementById("theme").onclick=e=>{let on=document.body.classList.toggle("dark");e.currentTarget.textContent=on?"Светлый фон":"Тёмный фон"};document.querySelectorAll(".card").forEach(card=>card.onclick=()=>{document.getElementById("title").textContent=card.dataset.label;let im=document.getElementById("zoom");im.dataset.base=card.dataset.base;im.src=card.dataset.base+(paused?".png":".webp");im.alt=card.dataset.label;document.getElementById("download").href=card.dataset.base+".webp";let id=card.dataset.base.split("/").pop();document.getElementById("gif").href=id+".gif";document.getElementById("png2k").href="png-2k/"+id+".png";document.getElementById("webm2k").href="webm-2k/"+id+".webm";document.getElementById("poses").href=id+"-contact.jpg";dialog.showModal()});dialog.querySelector(".close").onclick=()=>dialog.close();</script></html>'
(v/'index.html').write_text(page,encoding='utf-8')
checks=[]
for p in sorted((v/'original-poses').glob('*.png')):
 before=r/'matcha-motion-v6/poses'/p.name;assert p.read_bytes()==before.read_bytes();checks.append({'file':p.name,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
(v/'original-pose-checksums.json').write_text(json.dumps(checks,indent=2),encoding='utf-8')
(v/'README.md').write_text('''# Старые рисунки + дополнительные позы

Основа: версия 06, до сборки персонажа отдельными деталями.
288 исходных ключевых кадров сохранены побайтно в original-poses/.
Для cat-tired рабочие позы восстановлены из полного исходного листа
в corrected-poses/: прежняя сетка разрезала хвост между соседними ячейками.
В циклы добавлены нарисованные промежуточные позы, включая замыкание цикла.
Число добавленных рисунков и кадров указано для каждого стикера в manifest.json.
Цикл 6 секунд, сборка покадровая. Нет оптического потока, растягивания
рисунка между позами или сборки из отдельных лап.

Все 72 стикера дополнены. Количество новых рисунков указано в manifest.json.
В галерее — покадровые циклы с удержанием поз; это не 25 уникальных рисунков
в секунду. Версия 07 с отдельными лапами не используется.
Форматы: WebP 512, GIF 256 на светлом фоне, PNG и прозрачный WebM 2048.
2K — увеличенный экспорт из исходных рисунков меньшего разрешения.
Исходные рисунки, промежуточные листы и сценарии сборки сохранены рядом.
''',encoding='utf-8')
print(str(len(checks))+' original poses verified byte-for-byte; '+str(len(done))+' sticker completed')
