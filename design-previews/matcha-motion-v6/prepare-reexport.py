from pathlib import Path
p=Path('D:/projects/cubechat/design-previews/matcha-motion-v6/export-2k.py');s=p.read_text(encoding='utf-8-sig')
s=s.replace('exe=imageio_ffmpeg.get_ffmpeg_exe()',"exe=imageio_ffmpeg.get_ffmpeg_exe()\nrekey_ids={item['id'] for batch in json.loads((root/'batches.json').read_text(encoding='utf-8')) if batch['name']!='cat-1' for item in batch['items']} if '--rekey' in sys.argv else set()\nrekey_time=(root/'fix-key.py').stat().st_mtime")
s=s.replace(" while not (root/(stem+'.gif')).exists():time.sleep(1)"," while not (root/(stem+'.gif')).exists():time.sleep(1)\n if stem in rekey_ids:\n  while (root/(stem+'.gif')).stat().st_mtime<rekey_time:time.sleep(1)")
s=s.replace('if not dest.exists():','if not dest.exists() or stem in rekey_ids:')
p.write_text(s,encoding='utf-8')
