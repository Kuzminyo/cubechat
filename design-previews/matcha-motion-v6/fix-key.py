from pathlib import Path
root=Path('D:/projects/cubechat/design-previews/matcha-motion-v6')
p=root/'build-motion.py';s=p.read_text(encoding='utf-8-sig')
s=s.replace('bg=(diff>130).astype(np.uint8)','bg=((diff>65)&(rgb[:,:,0]>100)&(rgb[:,:,2]>100)).astype(np.uint8)')
s=s.replace('a[border]=np.clip(1-diff[border]/250,0,1)','a[border]=np.clip(1-diff[border]/90,0,1)').replace('a[diff>235]=0','a[bg>0]=0')
s=s.replace("selected={s:p for s,p in all_poses.items() if not (ROOT/(s+'.webp')).exists()} if '--sample' not in sys.argv else", "selected={s:p for s,p in all_poses.items() if (not (ROOT/(s+'.webp')).exists()) or ('--rekey' in sys.argv and s not in {kind+'-'+name for kind,_,names in OLD for name in names} and s not in ['cat-thanks','cat-thinking','cat-facepalm','cat-hug','cat-tired','cat-waiting'])} if '--sample' not in sys.argv else")
p.write_text(s,encoding='utf-8')
print('Chroma key cleanup corrected')
