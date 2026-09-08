from pathlib import Path
import sys,json
sys.path.insert(0,'C:/Users/kuzme/AppData/Local/Temp/cubechat-sticker-tools')
import cv2
from PIL import Image,ImageDraw
root=Path('D:/projects/cubechat/design-previews/motion-quality');root.mkdir(exist_ok=True)
cap=cv2.VideoCapture('C:/Users/kuzme/Downloads/video_2026-09-07_12-39-49.mp4')
fps=cap.get(cv2.CAP_PROP_FPS);frames=cap.get(cv2.CAP_PROP_FRAME_COUNT);duration=frames/fps
sheet=Image.new('RGB',(1000,1200),'#f4f3ea');draw=ImageDraw.Draw(sheet)
for i in range(12):
 t=duration*i/12;cap.set(cv2.CAP_PROP_POS_MSEC,t*1000);ok,f=cap.read()
 if ok:
  im=Image.fromarray(cv2.cvtColor(f,cv2.COLOR_BGR2RGB));im.thumbnail((245,365));x=(i%4)*250;y=(i//4)*400;sheet.paste(im,(x,y));draw.text((x+5,y+375),str(round(t,2))+' s',fill='#253322')
sheet.save(root/'user-video-contact.jpg',quality=88)
print(json.dumps({'fps':fps,'frames':frames,'duration':duration,'width':cap.get(cv2.CAP_PROP_FRAME_WIDTH),'height':cap.get(cv2.CAP_PROP_FRAME_HEIGHT)}))
