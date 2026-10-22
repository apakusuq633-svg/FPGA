"""Read-only release precheck while the final continuous replay is still active."""
from pathlib import Path
import re,json
R=Path(__file__).resolve().parents[1];script=R/'scripts/finalize_integrated_release.py'
prefix=script.read_text().split('long=load(',1)[0]
scope={'__file__':str(script),'__name__':'__precheck__'}
exec(compile(prefix,str(script),'exec'),scope)
V=R/'build/zynq12_integrated_plan/m5_validation_release'
t=(V/'extended4096_verified/run.log').read_text()
done=re.findall(r'^SAFETY_WINDOW id=(\d+) .* min_margin=\d+$',t,re.M)
data={'status':'PARTIAL_WAITING_FOR_LONG_REPLAY','release_source_and_completed_tests_precheck':'OK',
      'logged_complete_windows':int(done[-1])if done else 0,'target_windows':4096,
      'long_summary_present':'SAFETY_SUMMARY status=PASS windows=4096' in t}
print(json.dumps(data))
