from pathlib import Path
import sys,subprocess,json,time,io
from concurrent.futures import ThreadPoolExecutor,as_completed
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import imageio_ffmpeg
from PIL import Image
root=Path(__file__).resolve().parent
items=[x for x in json.loads((root/'manifest.json').read_text(encoding='utf-8')) if x.get('added_in')=='04']
exe=imageio_ffmpeg.get_ffmpeg_exe()
def export(item):
 stem=item['id'];dest=root/'webm-2k'/(stem+'.webm')
 src=Image.open(root/(stem+'.webp'))
 if not dest.exists():
  w,h=src.size
  cmd=[exe,'-v','error','-y','-f','rawvideo','-pix_fmt','rgba','-s',str(w)+'x'+str(h),'-r','25','-i','pipe:0','-vf','scale=2048:2048:flags=lanczos','-c:v','libvpx-vp9','-pix_fmt','yuva420p','-b:v','0','-crf','26','-deadline','realtime','-cpu-used','8','-row-mt','1','-threads','2','-auto-alt-ref','0','-an',str(dest)]
  process=subprocess.Popen(cmd,stdin=subprocess.PIPE,stderr=subprocess.PIPE)
  count=0
  for i in range(src.n_frames):
   src.seek(i);src.load();data=src.convert('RGBA').tobytes()
   for j in range(max(1,round(src.info.get('duration',40)/40))):process.stdin.write(data);count+=1
  process.stdin.close();error=process.stderr.read().decode();rc=process.wait()
  assert rc==0,(stem,error)
  assert count==100,(stem,count)
 # Decode an actual video frame with the alpha-capable VP9 decoder.
 decoded=subprocess.run([exe,'-v','error','-c:v','libvpx-vp9','-i',str(dest),'-frames:v','1','-f','image2pipe','-vcodec','png','pipe:1'],capture_output=True,check=True)
 check=Image.open(io.BytesIO(decoded.stdout))
 assert check.size==(2048,2048),(stem,check.size)
 assert check.mode=='RGBA',(stem,check.mode)
 low,high=check.getchannel('A').getextrema()
 assert low==0 and high==255,(stem,low,high)
 with Image.open(root/'png-2k'/(stem+'.png')) as still:assert still.size==(2048,2048)
 print(stem+' 2K verified',flush=True)
 return {'id':stem,'size':[2048,2048],'alpha':True,'cycle_ms':4000,'webm_bytes':dest.stat().st_size,'source_upscaled':True}
start=time.time();result=json.loads((root.parent/'matcha-motion-v3'/'validation-2k.json').read_text(encoding='utf-8'))
with ThreadPoolExecutor(max_workers=4) as pool:
 futures=[pool.submit(export,item) for item in items]
 for f in as_completed(futures):result.append(f.result())
(root/'validation-2k.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps({'verified_2k_animations':len(result),'seconds':round(time.time()-start)},indent=2),flush=True)

