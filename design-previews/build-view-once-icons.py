from pathlib import Path
import json
root = Path('D:/projects/cubechat/design-previews/view-once-icons')
root.mkdir(parents=True, exist_ok=True)
(root/'svg').mkdir(exist_ok=True)
(root/'png-2k').mkdir(exist_ok=True)
line = 'fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round"'
one = '<path d="m9 12.2 1.8-1.2v6"/>'
fuse = '<path d="M16.35 7.35c-.95-1.55-.6-3.5 1.5-3.5h1.3"/>'
spark = '<path d="M21 2.8V1.6m1.1 2.3 1-.5m-1.2 2 .8.8"/>'
icons = {
'01-orbit': '<g '+line+'><path d="m14.5 7.7 1.2-1.2 1.8 1.8-1.2 1.2a7 7 0 1 1-1.8-1.8Z"/>'+fuse+spark+one+'</g>',
}
names=['Орбита']
desc=['Мягкий контур · лёгкая и универсальная']
def svg(body, color=None):
    return '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"'+(' style="color:'+color+'"' if color else '')+'>'+body+'</svg>'
cards=[]
for i,(key,body) in enumerate(icons.items()):
    (root/'svg'/f'{key}.svg').write_text(svg(body),encoding='utf-8')
    samples=''.join('<span>'+svg(body)+'<small>'+str(size)+'</small></span>' for size in [20,24,32])
    cards.append(f'''<article><div class="card-top"><span>0{i+1}</span><span>{names[i]}</span></div><div class="hero">{svg(body)}</div><p>{desc[i]}</p><div class="samples">{samples}</div><a href="svg/{key}.svg" download>Скачать SVG <span>↗</span></a></article>''')
html='''<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CubeChat — одноразовый просмотр</title><style>
*{box-sizing:border-box}body{margin:0;background:#101512;color:#eef1e8;font-family:Inter,Segoe UI,Arial,sans-serif}main{max-width:1180px;margin:auto;padding:54px 48px 40px}.eyebrow{font-size:11px;letter-spacing:2px;color:#a3b58f;display:flex;justify-content:space-between}h1{font-size:38px;font-weight:500;letter-spacing:-1.5px;margin:25px 0 12px}header p{font-size:14px;color:#9da69f;margin:0}.grid{display:grid;grid-template-columns:minmax(0,480px);justify-content:center;gap:18px;margin-top:36px}article{border:1px solid #333e34;border-radius:20px;background:#19211b;padding:22px}.card-top{display:flex;gap:13px;align-items:center;font-size:13px}.card-top span:first-child{font-size:11px;color:#8fa082}.hero{height:180px;display:grid;place-items:center;color:#b2c49b}.hero svg{width:106px;height:106px}article p{font-size:11px;color:#b3bdb4;min-height:15px;margin:6px 0 24px}.samples{display:flex;align-items:start;justify-content:space-around;border-top:1px solid #333e34;padding-top:24px;height:88px}.samples span{display:flex;flex-direction:column;align-items:center;gap:12px}.samples span:nth-child(1) svg{width:20px;height:20px}.samples span:nth-child(2) svg{width:24px;height:24px}.samples span:nth-child(3) svg{width:32px;height:32px}.samples small{font-size:10px;color:#849184}a{color:#c0cfb0;text-decoration:none;font-size:11px;display:flex;justify-content:space-between;padding-top:19px}a:hover{color:white}.context{margin-top:28px;display:grid;grid-template-columns:1fr 1fr;gap:18px}.tile{border-radius:18px;padding:22px 25px;display:flex;justify-content:space-between;align-items:center;background:#e9ede2;color:#253125}.tile.dark{background:#202c24;color:#e9ede2}.tile small{display:block;font-size:10px;margin-bottom:11px;opacity:.65}.chip{display:flex;align-items:center;gap:9px;font-size:12px}.chip svg{width:24px;height:24px}.toggle{width:41px;height:24px;border-radius:30px;background:#81976c;padding:3px}.toggle:after{content:'';display:block;width:18px;height:18px;border-radius:50%;background:#fff;margin-left:17px}.dark .toggle{background:#2edb8f}.dark .chip svg{color:#2edb8f}footer{display:flex;justify-content:space-between;color:#839080;font-size:10px;margin-top:25px;letter-spacing:.4px}@media(max-width:700px){main{padding:30px 20px}.grid{grid-template-columns:1fr}.context{grid-template-columns:1fr}h1{font-size:29px}footer{gap:20px}}
</style><main><header><div class="eyebrow"><span>CUBECHAT / VIEW ONCE</span><span>ВАРИАНТ 01</span></div><h1>Один просмотр. Короткий фитиль.</h1><p>Орбита — выбранная иконка одноразового просмотра.</p></header><section class="grid">'''+''.join(cards)+'''</section><section class="context"><div class="tile"><div><small>В СВЕТЛОМ ИНТЕРФЕЙСЕ</small><div class="chip">'''+svg(icons['01-orbit'])+'''<span>Один просмотр</span></div></div><div class="toggle"></div></div><div class="tile dark"><div><small>В ТЁМНОМ ИНТЕРФЕЙСЕ</small><div class="chip">'''+svg(icons['01-orbit'])+'''<span>Один просмотр</span></div></div><div class="toggle"></div></div></section><footer><span>SVG · ПРОЗРАЧНЫЙ ФОН · PNG 2048 × 2048</span><span>20 / 24 / 32 PX</span></footer></main></html>'''
(root/'index.html').write_text(html,encoding='utf-8')
(root/'README.md').write_text('''# Иконки одноразового просмотра

Выбран первый вариант: 01-orbit — контурная бомба с фитилём. Остальные варианты исключены из набора.

- `index.html` — выбранная иконка и примеры на светлом и тёмном фоне.
- `svg/` — исходники, сетка 24 × 24, цвет через `currentColor`. Цифра 1 нарисована контурами, шрифты не нужны.
- `png-2k/` — прозрачные PNG 2048 × 2048 в цветах ink, white, matcha.
- `preview.png` — общий макет.

Первый вариант выбран пользователем. Текущие иконки в приложении пока не заменены. При интеграции брать цвет из AppColors. Для кнопки сохранять область нажатия минимум 48 × 48, видимый знак 24 × 24.
''',encoding='utf-8')
print(root)
