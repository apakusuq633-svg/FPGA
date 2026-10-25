"""Embed readable UTF-8 browser code as portable ASCII C string literals."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
if (ROOT/'profiles/full_gui9/page_template.html').exists():
 import runpy
 runpy.run_path(str(ROOT/'profiles/full_gui9/make_ui.py'),run_name='__main__')
 raise SystemExit(0)
p=ROOT/'sw/ps_ui_page.h'
s=p.read_text(encoding='utf-8')
start=s.index('"var c9busy')
end=s.index('"</script></main></body></html>\\n";',start)
js=(ROOT/'sw/circular9_ui.js').read_text(encoding='utf-8')
encoded=''.join(json.dumps(line+'\n',ensure_ascii=True).replace('\\u','\\\\u')+'\n' for line in js.splitlines())
p.write_text(s[:start]+encoded+s[end:],encoding='utf-8',newline='\n')
