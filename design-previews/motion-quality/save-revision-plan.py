from pathlib import Path
import json
r=Path('D:/projects/cubechat/design-previews/motion-quality')
items=json.loads((r.parent/'matcha-motion-v6/manifest.json').read_text(encoding='utf-8'))
prototypes={'cat-morning','cat-laugh','cat-flower','cat-victory'}
variants={'cat-sleep':'sleeping-body','cat-tired':'lying-body','cat-hurry':'running-body','cat-peek':'box-body'}
props={'cat-love':'heart','cat-party':'party-popper','cat-matcha':'cup','cat-cool':'sunglasses','cat-waiting':'hourglass','cat-victory':'trophy','cat-cozy':'blanket','cat-flower':'flower','cat-cookie':'cookie','cat-work':'laptop','cat-birthday':'cake','cat-music':'headphones','cat-gaming':'controller','cat-rain':'umbrella','cat-support':'pompoms','cat-recover':'scarf-bandage','cat-popcorn':'popcorn'}
plan=[]
for x in items:
 plan.append({'id':x['id'],'label':x['label'],'status':'prototype_under_visual_review' if x['id'] in prototypes else 'pending','rig':variants.get(x['id'],'seated-cat' if x['kind']=='cat' else 'emoji-features'),'prop':props.get(x['id']),'acceptance':['stable outer shape except intentional rigid motion','readable action instead of idle wobble','consistent identity and feature anchors','no optical flow, full-drawing morph or ghosting','clean attachments and single outer outline where appropriate','slow loop, transparent export, visual check at chat and enlarged sizes']})
(r/'revision-plan.json').write_text(json.dumps(plan,ensure_ascii=False,indent=2),encoding='utf-8')
(r/'STATUS.md').write_text('''# Working status — full 72 animation quality revision

Goal is ACTIVE and NOT complete. v6 is the rejected morphing version.
User video confirms changing outlines/face identity during optical-flow transitions.

Current artifacts:
- build-rig-prototype.py: new rigid cutout renderer, no optical flow. Includes
  fixed core, arm rotations, two-bone IK grip anchors, eyes/mouth states, props,
  fixed part scales, clean single outline after part compositing.
- parts/: 12 components from built-in ImageGen rig-sheet.png.
- rig-refined-contact.jpg: visual inspection of four video actions across 6 phases.
- cat-*-rig.webp: four working animation previews (export may be running).
- revision-plan.json: all 72 IDs and pending work; prototype != accepted final.

Done this turn: diagnosed actual user video, replaced the technique in a four-item
prototype, corrected IK sign and measured palm anchors, removed white internal
seams, avoided sustained squashed eyes, preserved continuous slow motion.

Still required: finish visual comparison with approved character appearance;
check all frames/loops and dark background; refine paw pose/character fidelity;
implement the remaining 32 cats (including 4 different body poses and props)
and all 36 emoji with stable feature animation; export final transparent media
and 2K files; replace latest catalog only when the whole collection is ready;
verify every one of the 72 actions visually, not only media metadata.

Do not mark the goal complete based on these four prototypes or decoding checks.
''',encoding='utf-8')
print('Full-scope revision plan saved: 4 prototypes under review, 68 pending')
