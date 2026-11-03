"""Negative control: accepted, deliberately wrong PHAT must still fail Golden."""
from pathlib import Path
import argparse,json,sys
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output.resolve()
original=R/'scripts/check_localizer12_safety.py';code=original.read_text()
needle="wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))"
assert code.count(needle)==1
code=code.replace(needle,"wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace('assign phi_value=dut.loc_ac_result;',\"assign phi_value=dut.loc_ac_result ^ 32'd1;\").replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))")
sys.argv=[str(original),'--output',str(O),'--windows','4','--report-name','corrupt_accepted_phi']
ns={'__file__':str(original),'__name__':'__main__'}
try:exec(compile(code,str(original),'exec'),ns)
except SystemExit as e:assert e.code==1,e.code
row=json.loads((O/'corrupt_accepted_phi_summary.json').read_text())['results'][0]
text=(R/row['log']).read_text();assert row['status']=='ERROR' and 'reason=PHAT_GOLDEN' in text and 'first_loss=0' in text
(O/'negative_control.json').write_text(json.dumps(dict(status='PASS_REJECTED_CORRUPT_ACCEPTED_PHAT',
 production_data_path_changed=False,checker_injection='XOR one accepted observation bit',observed_failure=row),indent=2))
(O/'executed_driver.py').write_text(code)
print('LOCALIZER12_ACCEPTED_PHAT_NEGATIVE_CONTROL_PASS')
