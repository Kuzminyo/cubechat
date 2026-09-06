from pathlib import Path
base=Path('D:/projects/cubechat/design-previews/matcha-motion-v3')
root=base.parent/'matcha-motion-v4'
root.mkdir(exist_ok=True)
s=(base/'build-collection.py').read_text(encoding='utf-8-sig')
s=s.replace("BASE=ROOT.parent/'matcha-motion-v2'","BASE=ROOT.parent/'matcha-motion-v3'")
s=s.replace(" shutil.copy2(BASE/(item['id']+'.png'),ROOT/'masters'/(item['id']+'.png'))\n item['added_in']='02'"," shutil.copy2(BASE/'masters'/(item['id']+'.png'),ROOT/'masters'/(item['id']+'.png'))\n for folder,ext in [('png-2k','.png'),('webm-2k','.webm')]:shutil.copy2(BASE/folder/(item['id']+ext),ROOT/folder/(item['id']+ext))")
a=s.index('NEW=[');b=s.index('\nnew=[]',a)
s=s[:a]+"""NEW=[
('cat','exec-e1e3d536-b2ad-4870-8eb3-b0f68c87491c.png',['morning','cozy','flower','cookie','work','hurry','birthday','nope'],['Доброе утро','Уютно','Это тебе','Вкусно','Работаю','Уже бегу','С днём рождения','Нет']),
('emoji','exec-339292c4-8c33-4782-85ec-45e8129fde00.png',['grin','rofl','tongue','relieved','skeptical','unamused','pleading','starry'],['Улыбка до ушей','Не могу со смеху','Дразнюсь','Выдохнул','Серьёзно?','Не впечатлён','Ну пожалуйста','Восторг'])]"""+s[b:]
cases="""   elif stem=='cat-morning':
    field(m,*point(.20,.40),0,-5*u,w*.19,h*.24)
    field(m,*point(.79,.47),0,-5*u,w*.19,h*.24)
    pulse(m,*point(.5,.63),.015*u,w*.38,h*.35)
   elif stem=='cat-cozy':
    pulse(m,*point(.53,.68),.018*u,w*.43,h*.32)
    rotate(m,headx,heady,.012*v,w*.42,h*.30)
   elif stem=='cat-flower':
    rotate(m,*point(.34,.57),.035*v,w*.23,h*.35)
    rotate(m,headx,heady,.014*v,w*.42,h*.32)
   elif stem=='cat-cookie':
    field(m,*point(.5,.61),0,-4*u,w*.25,h*.23)
    pulse(m,*point(.48,.4),.01*u,w*.28,h*.23)
   elif stem=='cat-work':
    field(m,*point(.73,.8),2*math.sin(4*math.pi*phase),-2*u,w*.15,h*.15)
    field(m,headx,heady,0,2.5*u,w*.40,h*.30)
   elif stem=='cat-hurry':
    field(m,cx,cy,0,-4*u,w*.6,h*.6)
    field(m,*point(.72,.78),4*v,-2*u,w*.2,h*.16)
    field(m,*point(.40,.80),-4*v,-2*u,w*.2,h*.16)
   elif stem=='cat-birthday':
    field(m,*point(.37,.62),0,-3*u,w*.25,h*.24)
    field(m,*point(.36,.45),1.5*v,-1*u,w*.10,h*.11)
   elif stem=='cat-nope':
    rotate(m,headx,heady,.024*v,w*.44,h*.34)
"""
s=s.replace("  elif stem=='emoji-clap':",cases+"  elif stem=='emoji-clap':")
cases="""   elif stem=='emoji-grin':
    pulse(m,*point(.5,.67),.02*u,w*.34,h*.18)
   elif stem=='emoji-rofl':
    rotate(m,cx,cy,.045*v,w*.62,h*.62)
    field(m,*point(.5,.58),0,-3*u,w*.32,h*.27)
   elif stem=='emoji-tongue':
    field(m,*point(.56,.76),1.5*v,3*u,w*.18,h*.19)
   elif stem=='emoji-relieved':
    pulse(m,cx,cy,.012*u,w*.5,h*.5)
   elif stem=='emoji-skeptical':
    field(m,*point(.67,.22),0,-3*u,w*.2,h*.15)
   elif stem=='emoji-unamused':
    field(m,*point(.33,.44),1.5*v,0,w*.16,h*.14)
    field(m,*point(.68,.44),1.5*v,0,w*.16,h*.14)
   elif stem=='emoji-pleading':
    pulse(m,*point(.34,.47),.022*u,w*.17,h*.22)
    pulse(m,*point(.66,.47),.022*u,w*.17,h*.22)
   elif stem=='emoji-starry':
    pulse(m,*point(.32,.40),.045*u,w*.19,h*.20)
    pulse(m,*point(.68,.40),.045*u,w*.19,h*.20)
"""
s=s.replace("  output.append(straight_image(remap(a,m)))",cases+"  output.append(straight_image(remap(a,m)))")
s=s.replace("'added_in':'03'","'added_in':'04'")
s=s.replace("for item in all_items:\n raw=","for item in all_items:\n if item.get('added_in')!='04':continue\n raw=")
s=s.replace('40 standard animations and 40 PNG 2K masters ready','56 standard animations and 56 PNG 2K masters ready')
(root/'build-collection.py').write_text(s,encoding='utf-8')
v=(base/'export-2k.py').read_text(encoding='utf-8-sig')
v=v.replace("items=json.loads((root/'manifest.json').read_text(encoding='utf-8'))","items=[x for x in json.loads((root/'manifest.json').read_text(encoding='utf-8')) if x.get('added_in')=='04']")
v=v.replace("if not dest.exists() or stem!='cat-wave':","if not dest.exists():")
v=v.replace("start=time.time();result=[]","start=time.time();result=json.loads((root.parent/'matcha-motion-v3'/'validation-2k.json').read_text(encoding='utf-8'))")
(root/'export-2k.py').write_text(v,encoding='utf-8')
print('Prepared collection 04')

