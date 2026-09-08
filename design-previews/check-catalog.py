from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit,unquote
import json,urllib.request
root=Path('D:/projects/cubechat/design-previews');missing=[]
class Links(HTMLParser):
 def handle_starttag(self,tag,attrs):
  for k,v in attrs:
   if k in ('src','href') and v and not urlsplit(v).scheme and not v.startswith('#'):
    p=(self.base/unquote(v.split('?')[0])).resolve()
    if not p.exists():missing.append(str(p))
for p in [root/'index.html',root/'source-art/index.html',root/'matcha-motion-v7/index.html',root/'matcha-motion-v7/compare.html',root/'matcha-motion-v7/first-eight.html']:
 parser=Links();parser.base=p.parent;parser.feed(p.read_text(encoding='utf-8'))
endpoint=json.loads((root/'matcha-motion-v7/preview-server.json').read_text())['url'].rsplit('matcha-motion-v7/',1)[0]
try:
 with urllib.request.urlopen(endpoint,timeout=3) as response:status=response.status
except Exception:status=None
result={'checked_pages':5,'missing_local_assets':missing,'catalog_url':endpoint,'server_status':status}
(root/'validation-catalog.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result))
assert not missing
