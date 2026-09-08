from pathlib import Path
import sys,json,subprocess,io,bisect,time
from concurrent.futures import ThreadPoolExecutor,as_completed
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import imageio_ffmpeg
from PIL import Image
r=Path(__file__).resolve().parent;items=json.loads((r/'manifest.json').read_text(encoding='utf-8'));exe=imageio_ffmpeg.get_ffmpeg_exe()
for name in ['png-2k','webm-2k']:(r/name).mkdir(exist_ok=True)
def export(item):
 stem=item['id'];src=Image.open(r/(stem+'.webp'));poses=[];dur=[]
 for i in range(src.n_frames):
  src.seek(i);src.load();poses.append(src.convert('RGBA'));dur.append(src.info['duration'])
 assert sum(dur)==6000,(stem,dur)
 poses[0].resize((2048,2048),Image.Resampling.LANCZOS).save(r/'png-2k'/(stem+'.png'))
 rgb=[]
 for frame in poses:
  bg=Image.new('RGBA',(512,512),'#f4f3ea');bg.alpha_composite(frame);rgb.append(bg.resize((256,256),Image.Resampling.LANCZOS).convert('RGB'))
 strip=Image.new('RGB',(256*len(rgb),256))
 for i,im in enumerate(rgb):strip.paste(im,(256*i,0))
 palette=strip.quantize(colors=256,method=Image.Quantize.MEDIANCUT);gif=[fr.quantize(palette=palette,dither=Image.Dither.NONE) for fr in rgb]
 gif[0].save(r/(stem+'.gif'),save_all=True,append_images=gif[1:],duration=dur,loop=0,disposal=1,optimize=True)
 ends=[];elapsed=0
 for d in dur:elapsed+=d;ends.append(elapsed)
 path=r/'webm-2k'/(stem+'.webm')
 cmd=[exe,'-v','error','-y','-f','rawvideo','-pix_fmt','rgba','-s','512x512','-r','25','-i','pipe:0','-vf','scale=2048:2048:flags=lanczos','-c:v','libvpx-vp9','-pix_fmt','yuva420p','-b:v','0','-crf','24','-deadline','realtime','-cpu-used','8','-row-mt','1','-threads','2','-auto-alt-ref','0','-an',str(path)]
 process=subprocess.Popen(cmd,stdin=subprocess.PIPE,stderr=subprocess.PIPE)
 for t in range(0,6000,40):process.stdin.write(poses[bisect.bisect_right(ends,t)].tobytes())
 process.stdin.close();error=process.stderr.read().decode();rc=process.wait();assert rc==0,(stem,error)
 decoded=subprocess.run([exe,'-v','error','-c:v','libvpx-vp9','-i',str(path),'-frames:v','1','-f','image2pipe','-vcodec','png','pipe:1'],capture_output=True,check=True);check=Image.open(io.BytesIO(decoded.stdout));assert check.size==(2048,2048) and check.mode=='RGBA' and check.getchannel('A').getextrema()==(0,255)
 print(stem+' exported and 2K alpha checked',flush=True)
 return {'id':stem,'cycle_ms':6000,'webp_frames':len(poses),'size':[2048,2048],'alpha':True,'source_upscaled':True}
if __name__=='__main__':
 start=time.time();selected=[x for x in items if len(sys.argv)<2 or x['id'] in sys.argv[1:]];results=[]
 with ThreadPoolExecutor(max_workers=3) as pool:
  for f in as_completed([pool.submit(export,x) for x in selected]):results.append(f.result())
 report=r/'validation-exports.json';previous=json.loads(report.read_text(encoding='utf-8')) if report.exists() else [];merged={x['id']:x for x in previous};merged.update({x['id']:x for x in results});report.write_text(json.dumps(list(merged.values()),indent=2),encoding='utf-8');print(json.dumps({'exported':len(results),'seconds':round(time.time()-start)}),flush=True)
