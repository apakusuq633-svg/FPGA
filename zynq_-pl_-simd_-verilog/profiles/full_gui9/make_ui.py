"""Regenerate the embedded nine-mic page from this profile's readable sources."""
from pathlib import Path
import json,re
P=Path(__file__).resolve().parent
R=P.parents[1]
def main():
 html=(P/'page_template.html').read_text(encoding='utf-8')
 config=json.loads((R/'configs/circular9_array.json').read_text(encoding='utf-8'))
 positions=config['channel_positions_m']
 if len(positions)!=9 or any(len(p)!=3 for p in positions):raise ValueError('Nine channel-order positions required')
 geometry_js='var c9ChannelPositions='+json.dumps(positions,separators=(',',':'),allow_nan=False)+';\n'
 html=html.replace('{{GCC_CORE}}',(R/'sw/circular9_gcc_debug.js').read_text(encoding='utf-8')).replace('{{GUI9_JS}}',geometry_js+(R/'sw/circular9_full_gui.js').read_text(encoding='utf-8'))
 if len(html.encode())>=60000:raise ValueError('Page exceeds the bounded 16-bit HTTP response budget')
 def encode(line):
  raw=json.dumps(line+'\n',ensure_ascii=False)
  return ''.join(c if ord(c)<128 else ''.join('\\%03o'%b for b in c.encode()) for c in raw).replace('??','?\\?')
 page=R/'sw/ps_ui_page.h';s=page.read_text(encoding='utf-8-sig')
 pattern=r'static const char UI_PAGE_HTML\[\]\s*=\s*((?:"(?:\\.|[^"\\])*"\s*)+);'
 m=re.search(pattern,s)
 if not m:raise ValueError('UI_PAGE_HTML not found')
 encoded='\n'.join(encode(line) for line in html.splitlines())
 page.write_text(s[:m.start()]+'static const char UI_PAGE_HTML[] =\n'+encoded+';'+s[m.end():],encoding='utf-8',newline='\n')
 print('FULL_GUI9_PAGE_PASS bytes='+str(len(html.encode())))
if __name__=='__main__':main()
