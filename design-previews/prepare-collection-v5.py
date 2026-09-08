from pathlib import Path
base=Path('D:/projects/cubechat/design-previews/matcha-motion-v4')
root=base.parent/'matcha-motion-v5'
root.mkdir(exist_ok=True)
s=(base/'build-collection.py').read_text(encoding='utf-8-sig')
s=s.replace("BASE=ROOT.parent/'matcha-motion-v3'","BASE=ROOT.parent/'matcha-motion-v4'")
a=s.index('NEW=[');b=s.index('\nnew=[]',a)
s=s[:a]+"""NEW=[
('cat','exec-3121c3af-bf4d-41f2-9255-af9cb1040688.png',['music','gaming','rain','peek','secret','support','recover','popcorn'],['На своей волне','Играю','Не мой день','Я тут','Тсс…','Ты справишься','Поправляюсь','Наблюдаю']),
('emoji','exec-510e64cb-0d08-4e74-8694-5829f3e1102c.png',['zipper','shush','hugging','salute','sweat','mindblown','sobbing','angel'],['Молчу','Тсс…','Обнимаю','Есть!','Неловко','Взрыв мозга','Рыдаю','Ангелочек'])]"""+s[b:]
s=s.replace("'added_in':'04'","'added_in':'05'").replace("item.get('added_in')!='04'","item.get('added_in')!='05'")
s=s.replace('56 standard animations and 56 PNG 2K masters ready','72 standard animations and 72 PNG 2K masters ready')
cases="""   elif stem=='cat-music':
    rotate(m,headx,heady,.027*v,w*.45,h*.34)
    field(m,*point(.74,.52),0,-2*u,w*.17,h*.19)
   elif stem=='cat-gaming':
    field(m,*point(.5,.62),1.5*v,-2*u,w*.28,h*.20)
    field(m,*point(.29,.61),0,-1.5*math.sin(4*math.pi*phase),w*.13,h*.14)
   elif stem=='cat-rain':
    rotate(m,*point(.49,.24),.016*v,w*.48,h*.36)
    field(m,headx,heady,0,2*u,w*.35,h*.28)
   elif stem=='cat-peek':
    field(m,headx,heady,0,-4*u,w*.39,h*.31)
    field(m,*point(.45,.55),0,-2*u,w*.30,h*.15)
   elif stem=='cat-secret':
    rotate(m,headx,heady,.016*v,w*.41,h*.34)
    field(m,*point(.44,.61),0,-2*u,w*.15,h*.22)
   elif stem=='cat-support':
    field(m,*point(.20,.39),-2*v,-4*u,w*.23,h*.25)
    field(m,*point(.8,.38),2*v,-4*u,w*.23,h*.25)
   elif stem=='cat-recover':
    field(m,headx,heady,0,2*u,w*.42,h*.32)
    pulse(m,*point(.5,.65),.015*u,w*.39,h*.28)
   elif stem=='cat-popcorn':
    field(m,*point(.42,.53),0,-2*u,w*.19,h*.20)
    rotate(m,headx,heady,.016*v,w*.4,h*.30)
"""
s=s.replace("  elif stem=='emoji-clap':",cases+"  elif stem=='emoji-clap':")
cases="""   elif stem=='emoji-zipper':
    rotate(m,*point(.75,.7),.055*v,w*.18,h*.2)
   elif stem=='emoji-shush':
    field(m,*point(.5,.68),0,-2*u,w*.18,h*.25)
   elif stem=='emoji-hugging':
    field(m,*point(.23,.76),3*u,-1*u,w*.23,h*.25)
    field(m,*point(.79,.75),-3*u,-1*u,w*.23,h*.25)
   elif stem=='emoji-salute':
    rotate(m,*point(.29,.25),.026*v,w*.31,h*.24)
   elif stem=='emoji-sweat':
    field(m,*point(.2,.23),0,3*u,w*.14,h*.21)
    pulse(m,*point(.5,.69),.015*u,w*.31,h*.18)
   elif stem=='emoji-mindblown':
    pulse(m,*point(.49,.2),.028*u,w*.34,h*.23)
    field(m,*point(.49,.2),1.5*v,-3*u,w*.36,h*.23)
   elif stem=='emoji-sobbing':
    field(m,*point(.23,.69),0,3*u,w*.15,h*.28)
    field(m,*point(.79,.69),0,3*u,w*.15,h*.28)
   elif stem=='emoji-angel':
    field(m,*point(.5,.12),2*v,-2*u,w*.45,h*.15)
"""
s=s.replace("  output.append(straight_image(remap(a,m)))",cases+"  output.append(straight_image(remap(a,m)))")
(root/'build-collection.py').write_text(s,encoding='utf-8')
v=(base/'export-2k.py').read_text(encoding='utf-8-sig').replace("=='04'","=='05'").replace("root.parent/'matcha-motion-v3'","root.parent/'matcha-motion-v4'")
(root/'export-2k.py').write_text(v,encoding='utf-8')
u=(base/'build-preview.py').read_text(encoding='utf-8-sig').replace("'04'","'05'").replace('КОЛЛЕКЦИЯ 04','КОЛЛЕКЦИЯ 05').replace('Collection 04','Collection 05').replace('56','72').replace('28','36').replace('matcha-new-16-v4','matcha-new-16-v5')
u=u.replace('href="../matcha-motion-v3/index.html">Предыдущие 40','href="../matcha-motion-v4/index.html">Предыдущие 56')
u=u.replace('Cat: morning stretch, cozy blanket, flower, cookie, work, hurry, birthday, nope.','Cat: music, gaming, rain, peeking from a box, shush, support, recovery, popcorn.')
u=u.replace('Emoji: grin, rolling laughter, tongue, relieved, skeptical, unamused, pleading,\\nstarstruck.','Emoji: zipper, shush, hugging face, salute, nervous laugh, mind blown, sobbing, angel.')
(root/'build-preview.py').write_text(u,encoding='utf-8')
p=(base/'package.py').read_text(encoding='utf-8-sig').replace("=='04'","=='05'").replace('56','72').replace('28','36').replace('matcha-new-16-v4','matcha-new-16-v5')
p=p.replace('href="../matcha-motion-v3/index.html">Предыдущие 40','href="../matcha-motion-v4/index.html">Предыдущие 56')
(root/'package.py').write_text(p,encoding='utf-8')
c=(base/'check-preview.cjs').read_text(encoding='utf-8-sig').replace('matcha-motion-v4/','matcha-motion-v5/').replace('56','72').replace('cat-morning','cat-music')
(root/'check-preview.cjs').write_text(c,encoding='utf-8')
print('Collection 05 prepared')

