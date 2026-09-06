import sys,time,subprocess
from pathlib import Path
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import imageio_ffmpeg
from PIL import Image
root=Path('D:/projects/cubechat/design-previews/matcha-motion-v3')
(root/'webm-2k').mkdir(exist_ok=True)
src=Image.open('D:/projects/cubechat/design-previews/matcha-motion-v2/cat-wave.webp')
exe=imageio_ffmpeg.get_ffmpeg_exe()
cmd=[exe,'-v','error','-y','-f','rawvideo','-pix_fmt','rgba','-s','320x320','-r','25','-i','pipe:0','-vf','scale=2048:2048:flags=lanczos','-c:v','libvpx-vp9','-pix_fmt','yuva420p','-b:v','0','-crf','26','-deadline','realtime','-cpu-used','8','-row-mt','1','-threads','2','-auto-alt-ref','0','-an',str(root/'webm-2k/cat-wave.webm')]
start=time.time();p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stderr=subprocess.PIPE)
for i in range(src.n_frames):
 src.seek(i);src.load()
 data=src.convert('RGBA').tobytes()
 for repeat in range(max(1,round(src.info.get('duration',40)/40))):p.stdin.write(data)
p.stdin.close();err=p.stderr.read().decode();rc=p.wait()
assert rc==0,err
print({'seconds':round(time.time()-start,2),'bytes':(root/'webm-2k/cat-wave.webm').stat().st_size,'exe':exe})

