from pathlib import Path
import sys,subprocess,json,time,io,shutil
from concurrent.futures import ThreadPoolExecutor,as_completed
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import imageio_ffmpeg
from PIL import Image
ROOT=Path(__file__).resolve().parent;DEST=ROOT.parent/'matcha-motion-v7';DEST.mkdir(exist_ok=True)
for name in ['png-2k','webm-2k','sources']:(DEST/name).mkdir(exist_ok=True)
items=json.loads((ROOT.parent/'matcha-motion-v6/manifest.json').read_text(encoding='utf-8'))
for item in items:
 item.update({'cycle_ms':6000,'fps':25,'size_webp':[512,512],'source_upscaled':True,'motion_revision':'07','method':'fixed drawings with anchored feature and limb animation; rigid transforms; no optical flow or pose morphing'})
 for k in ['source_poses','sampled_frames']:item.pop(k,None)
(DEST/'manifest.json').write_text(json.dumps(items,ensure_ascii=False,indent=2),encoding='utf-8')
exe=imageio_ffmpeg.get_ffmpeg_exe()
for filename in ['rig-sheet.png','emoji-source-base.png','emoji-source-features.png','emoji-source-props.png','cat-source-props.png']:
 shutil.copy2(ROOT/filename,DEST/'sources'/filename)
def export(item):
 stem=item['id'];source=ROOT/(item['kind']+'-rig')/(stem+'.webp')
 if not source.exists():return None
 src=Image.open(source);frames=[]
 for i in range(src.n_frames):
  src.seek(i);src.load();frame=src.convert('RGBA')
  for j in range(max(1,round(src.info.get('duration',40)/40))):frames.append(frame.copy())
 assert len(frames)==150,(stem,len(frames))
 shutil.copy2(source,DEST/(stem+'.webp'));shutil.copy2(source.with_suffix('.png'),DEST/(stem+'.png'))
 frames[0].resize((2048,2048),Image.Resampling.LANCZOS).save(DEST/'png-2k'/(stem+'.png'),optimize=True)
 gifpath=DEST/(stem+'.gif')
 if not gifpath.exists() or gifpath.stat().st_mtime<source.stat().st_mtime:
  rgb=[]
  for frame in frames:
   bg=Image.new('RGBA',(512,512),'#f4f3ea');bg.alpha_composite(frame);rgb.append(bg.resize((256,256),Image.Resampling.LANCZOS).convert('RGB'))
  strip=Image.new('RGB',(256*6,256))
  for i,fi in enumerate([0,30,55,75,105,135]):strip.paste(rgb[fi],(256*i,0))
  palette=strip.quantize(colors=256,method=Image.Quantize.MEDIANCUT);gif=[fr.quantize(palette=palette,dither=Image.Dither.NONE) for fr in rgb]
  gif[0].save(gifpath,save_all=True,append_images=gif[1:],duration=40,loop=0,disposal=1,optimize=True)
 dest=DEST/'webm-2k'/(stem+'.webm')
 if not dest.exists() or dest.stat().st_mtime<source.stat().st_mtime:
  cmd=[exe,'-v','error','-y','-f','rawvideo','-pix_fmt','rgba','-s','512x512','-r','25','-i','pipe:0','-vf','scale=2048:2048:flags=lanczos','-c:v','libvpx-vp9','-pix_fmt','yuva420p','-b:v','0','-crf','24','-deadline','realtime','-cpu-used','8','-row-mt','1','-threads','2','-auto-alt-ref','0','-an',str(dest)]
  process=subprocess.Popen(cmd,stdin=subprocess.PIPE,stderr=subprocess.PIPE)
  for frame in frames:process.stdin.write(frame.tobytes())
  process.stdin.close();error=process.stderr.read().decode();rc=process.wait();assert rc==0,(stem,error)
 decoded=subprocess.run([exe,'-v','error','-c:v','libvpx-vp9','-i',str(dest),'-frames:v','1','-f','image2pipe','-vcodec','png','pipe:1'],capture_output=True,check=True)
 check=Image.open(io.BytesIO(decoded.stdout));assert check.size==(2048,2048) and check.mode=='RGBA';assert check.getchannel('A').getextrema()==(0,255)
 print(stem+' WebP / GIF / 2K PNG + WebM exported',flush=True)
 return {'id':stem,'size':[2048,2048],'alpha':True,'cycle_ms':6000,'webm_bytes':dest.stat().st_size,'source_upscaled':True}
if __name__=='__main__':
 selected=[x for x in items if (len(sys.argv)<2 or x['kind']==sys.argv[1]) and (len(sys.argv)<3 or x['id'] in sys.argv[2].split(','))];results=[];start=time.time()
 with ThreadPoolExecutor(max_workers=3) as pool:
  for f in as_completed([pool.submit(export,item) for item in selected]):
   r=f.result()
   if r:results.append(r)
 label=sys.argv[1] if len(sys.argv)>1 else 'all'
 report=DEST/('validation-2k-'+label+'.json')
 previous=json.loads(report.read_text()) if report.exists() else []
 merged={x['id']:x for x in previous}
 merged.update({x['id']:x for x in results})
 report.write_text(json.dumps(list(merged.values()),indent=2),encoding='utf-8')
 print(json.dumps({'exported':len(results),'seconds':round(time.time()-start)}),flush=True)
