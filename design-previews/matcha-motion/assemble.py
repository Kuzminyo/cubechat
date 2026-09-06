from pathlib import Path
from PIL import Image, ImageOps
import json, shutil, zipfile
root=Path(__file__).resolve().parent
source=Path('C:/Users/kuzme/.codex/generated_images/01a07721-3949-7910-9e64-eaae4d5bf0e0')
specs=[
('cat','exec-ab3a9cf2-1f92-4ef3-8417-5bd037c923d7.png',['wave','laugh','love','sleep'],['Привет','Смех','Любовь','Сон'],[[360,160,260,180],[170,170,170,240],[460,220,340,220],[650,500,650,500]]),
('emoji','exec-70fd9051-f89c-4732-aca7-c63ec5948460.png',['smile','laugh','heart','kiss'],['Улыбка','Смех','Сердце','Поцелуй'],[[1400,90,150,110],[180,180,180,260],[550,110,150,190],[500,200,240,460]])]
manifest=[]
animations=[]
sections=[]
for kind,filename,names,labels,durations in specs:
 sheet=Image.open(source/filename).convert('RGBA')
 shutil.copy2(source/filename,root/(kind+'-sheet.png'))
 w,h=sheet.size
 alpha=sheet.getchannel('A')
 rows=[0]
 for split in range(1,4):
  estimate=round(h*split/4)
  rows.append(min(range(estimate-24,estimate+25),key=lambda y:sum(alpha.crop((0,y,w,y+1)).point(lambda v:255 if v>200 else 0).getdata())))
 rows.append(h)
 cards=[]
 for row,name in enumerate(names):
  frames=[]
  for col in range(4):
   frame=sheet.crop((round(col*w/4),rows[row],round((col+1)*w/4),rows[row+1]))
   frames.append(ImageOps.pad(frame,(320,320),method=Image.Resampling.LANCZOS,color=(0,0,0,0)))
  stem=kind+'-'+name
  frames[0].save(root/(stem+'.webp'),save_all=True,append_images=frames[1:],duration=durations[row],loop=0,lossless=True)
  frames[0].save(root/(stem+'.png'))
  gifs=[]
  for frame in frames:
   bg=Image.new('RGBA',frame.size,'#f4f3ea');bg.alpha_composite(frame);gifs.append(bg.convert('RGB'))
  gifs[0].save(root/(stem+'.gif'),save_all=True,append_images=gifs[1:],duration=durations[row],loop=0,disposal=2)
  manifest.append({'id':stem,'frames':4,'duration_ms':durations[row],'size':[320,320]})
  animations.append((frames,durations[row]))
  cards.append('<article><img src="'+stem+'.webp" alt="'+labels[row]+'"><span>'+labels[row]+'</span></article>')
 sections.append('<section class="grid">'+''.join(cards)+'</section>')
preview=[]
for t in range(0,6000,100):
 canvas=Image.new('RGBA',(800,400),'#f4f3ea')
 for index,(frames,durations) in enumerate(animations):
  phase=t%sum(durations);fi=0
  while phase>=durations[fi]:phase-=durations[fi];fi+=1
  canvas.alpha_composite(frames[fi].resize((190,190),Image.Resampling.LANCZOS),((index%4)*200+5,(index//4)*200+5))
 preview.append(canvas.convert('RGB'))
preview[0].save(root/'animated-preview.gif',save_all=True,append_images=preview[1:],duration=100,loop=0,disposal=2)
preview[0].save(root/'preview-still.png')
(root/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
(root/'README.md').write_text("""# Matcha & Emoji
Eight animated visual concepts for CubeChat: matcha cat waving, laughing, love,
sleep; emoji smile, laugh, heart, kiss. Open index.html for a motion preview.
Four generated keyframes per animation; these are early motion studies, not
finished smooth production animation or Telegram TGS files. No app integration.
WebP retains generated transparency. GIF has an ivory background. 320x320 px.
Created with built-in ImageGen. Cat prompt: muted gray olive matcha #939B78,
cream muzzle and belly, white sticker edging, four animation frames per action.
Emoji prompt: classic compact yellow messenger emoji, small facial features,
subtle volume, no border, four successive frames per reaction.
""",encoding='utf-8')
html="""<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CubeChat — Matcha & Emoji</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#f4f3ea;color:#30382a;font:16px/1.5 system-ui,sans-serif}main{max-width:1000px;margin:auto;padding:40px 24px 60px}header{display:flex;justify-content:space-between;align-items:center;gap:20px}.eyebrow{font-size:12px;letter-spacing:.16em;color:#707957}h1{font-size:42px;font-weight:550;letter-spacing:-.05em;margin:6px 0}p{color:#737969;margin:6px 0 22px}.controls{display:flex;gap:8px}button,a{font:inherit;border:1px solid #cdd1bd;color:inherit;background:transparent;border-radius:24px;padding:9px 15px;cursor:pointer;text-decoration:none}button:hover,a:hover{background:#e4e7d6}h2{font-size:22px;font-weight:550;margin:28px 0 4px}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}article{background:#ffffff60;border:1px solid #dedfcf;border-radius:24px;text-align:center;padding:10px 8px 16px}article img{width:100%;aspect-ratio:1;object-fit:contain}article span{font-size:13px;color:#747c64}.mini{display:flex;gap:14px;align-items:center;min-height:70px;background:#e6eadb;border-radius:18px;padding:12px 20px;margin-top:18px}.mini img{width:32px;height:32px;object-fit:contain}.mini span{font-size:14px;margin-right:auto}.footer{margin:28px 0;font-size:13px}.swatch{display:inline-block;width:13px;height:13px;border-radius:50%;background:#939b78;margin-right:6px}body.dark{background:#20251f;color:#ebeedf}body.dark article{background:#2c3229;border-color:#3b4435}body.dark p,body.dark article span{color:#b8c0aa}body.dark .mini{background:#333d2e}body.dark button,body.dark a{border-color:#556047}body.dark button:hover{background:#3b4435}@media(max-width:650px){main{padding:25px 16px}header{display:block}h1{font-size:34px}.grid{grid-template-columns:repeat(2,1fr)}.mini{gap:8px}.controls{margin-top:18px}}
</style><main><header><div><div class="eyebrow">CUBECHAT · MOTION STUDY 01</div><h1>Matcha & Emoji</h1><p>Первые движения и эмоции для твоего чата.</p></div><div class="controls"><button id="pause">Пауза</button><button id="theme">Тёмный фон</button></div></header>
<h2>Котик матча</h2><p><span class="swatch"></span>Приглушённый оливковый с зелёным подтоном.</p>CAT_SECTION
<h2>Эмодзи</h2><p>Компактные реакции с мягкими тенями и без обводки.</p>EMOJI_SECTION
<div class="mini"><span>В размере сообщения</span><img src="emoji-smile.webp" alt="Улыбка"><img src="emoji-laugh.webp" alt="Смех"><img src="emoji-heart.webp" alt="Сердце"><img src="emoji-kiss.webp" alt="Поцелуй"></div>
<p class="footer">Пробные циклы из четырёх нарисованных кадров. Отдельные анимации — WebP с прозрачностью и GIF на светлом фоне.</p><a href="matcha-animated-pack.zip" download>Скачать оба набора</a></main>
<script>
let paused=matchMedia('(prefers-reduced-motion: reduce)').matches;
function sync(){document.querySelectorAll('img').forEach(img=>{img.src=img.src.replace(/\\.(webp|png)$/,paused?'.png':'.webp')});document.getElementById('pause').textContent=paused?'Воспроизвести':'Пауза'}
document.getElementById('pause').onclick=()=>{paused=!paused;sync()};document.getElementById('theme').onclick=()=>{const dark=document.body.classList.toggle('dark');document.getElementById('theme').textContent=dark?'Светлый фон':'Тёмный фон'};sync();
</script></html>"""
(root/'index.html').write_text(html.replace('CAT_SECTION',sections[0]).replace('EMOJI_SECTION',sections[1]),encoding='utf-8')
with zipfile.ZipFile(root/'matcha-animated-pack.zip','w',zipfile.ZIP_DEFLATED) as archive:
 for item in manifest:
  for suffix in ['.webp','.gif','.png']:
   path=root/(item['id']+suffix);archive.write(path,path.name)
 for name in ['manifest.json','README.md','index.html']:archive.write(root/name,name)
for item in manifest:
 for ext in ['webp','gif']:
  with Image.open(root/(item['id']+'.'+ext)) as check:
   assert check.n_frames==4,(item['id'],check.n_frames)
   assert check.size==(320,320)
   for i in range(check.n_frames):check.seek(i);check.load()
print(json.dumps({'verified_animations':len(manifest),'preview':str(root/'animated-preview.gif'),'archive':str(root/'matcha-animated-pack.zip')},indent=2))

