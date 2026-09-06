from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from functools import partial
from pathlib import Path
import json,os
root=Path(__file__).resolve().parent
server=ThreadingHTTPServer(('127.0.0.1',0),partial(SimpleHTTPRequestHandler,directory=str(root)))
(root/'preview-server.json').write_text(json.dumps({'pid':os.getpid(),'url':'http://127.0.0.1:'+str(server.server_address[1])+'/'}),encoding='utf-8')
server.serve_forever()

