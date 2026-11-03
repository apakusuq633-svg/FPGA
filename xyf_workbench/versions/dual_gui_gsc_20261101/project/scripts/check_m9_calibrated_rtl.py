"""Reuse the M7 arithmetic tests, preserving each otherwise-reused RTL log."""
from pathlib import Path
import hashlib,json,sys
R=Path(__file__).resolve().parents[1]
original=R/'scripts/check_m7_calibrated_rtl.py';code=original.read_text()
needle='    peak=int(m[1]);angle='
assert code.count(needle)==1
code=code.replace(needle,"    saved=O/f'case{i}_rtl.log';saved.write_text(text);row['log']=str(saved.relative_to(R))\n"+needle)
inputs={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [original,Path(__file__)]}
ns={'__file__':str(original),'__name__':'__main__'}
exec(compile(code,str(original),'exec'),ns)
O=ns['O'];(O/'driver_sources.json').write_text(json.dumps(inputs,indent=2))
(O/'executed_driver.py').write_text(code)
