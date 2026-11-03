"""Capture the real valid/ready state at the reproducible PHAT boundary error."""
from pathlib import Path
import argparse,json,sys
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();output=a.output.resolve()
original=R/'scripts/check_localizer12_safety.py';code=original.read_text()
# Reproduce the pre-fix checker without reverting the current testbench.
legacy=R/'build/m10_20261016/before/tb_localizer12_safety.v'
assert legacy.is_file()
ports=' output boundary_loss_now,boundary_run_ok,boundary_ac_start,boundary_ac_fire,\n input[16:0]debug_addr'
assigns='''assign boundary_loss_now=dut.g_localizer.u_transfer.loss_now;
 assign boundary_run_ok=dut.g_localizer.u_transfer.run_ok;
 assign boundary_ac_start=dut.loc_ac_start;
 assign boundary_ac_fire=dut.u_core.u_acoustic_ext.io_fire;
'''
needle="wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))"
assert code.count(needle)==1
code=code.replace(needle,"wrapper.write_text(Path("+repr(str(legacy))+").read_text().replace(' input[16:0]debug_addr',"+repr(ports)+").replace('endmodule',"+repr(assigns+'\nendmodule')+").replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))")
needle="files+=[R/'tb/tb_localizer12_safety.v',R/'scripts/localizer12_safety.cpp']"
replacement='''boundary_cpp=G/'localizer12_boundary.cpp'
boundary_text=(R/'scripts/localizer12_safety.cpp').read_text()
old='    if(top.phi_check){require'
new='    if(top.phi_check&&top.boundary_loss_now)std::cout<<"BOUNDARY_DIAG loss_now="<<unsigned(top.boundary_loss_now)<<" run_ok="<<unsigned(top.boundary_run_ok)<<" ac_start="<<unsigned(top.boundary_ac_start)<<" ac_fire="<<unsigned(top.boundary_ac_fire)<<" phi_check="<<unsigned(top.phi_check)<<" cycle="<<cycle<<std::endl;\\n'+old
assert boundary_text.count(old)==1
boundary_cpp.write_text(boundary_text.replace(old,new))
sources[str(boundary_cpp.relative_to(R))]=hashlib.sha256(boundary_cpp.read_bytes()).hexdigest()
files+=[R/'tb/tb_localizer12_safety.v',boundary_cpp]'''
assert code.count(needle)==1;code=code.replace(needle,replacement)
sys.argv=[str(original),'--output',str(output),'--kind','op','--phase','gccin','--duration','300000','--windows','4','--report-name','boundary']
ns={'__file__':str(original),'__name__':'__main__'}
try:exec(compile(code,str(original),'exec'),ns)
except SystemExit as e:assert e.code==1,e.code
summary=json.loads((output/'boundary_summary.json').read_text());row=summary['results'][0];text=(R/row['log']).read_text()
assert row['status']=='ERROR' and 'reason=PHAT_GOLDEN' in text
assert 'BOUNDARY_DIAG loss_now=1 run_ok=0 ac_start=0 ac_fire=0 phi_check=1' in text,text[-2000:]
(output/'diagnosis.json').write_text(json.dumps(dict(status='CONFIRMED_CHECKER_SAMPLED_UNACCEPTED_DATA',
 loss_cycle=1640454,diagnostic=text,original_failure=row,production_rtl_modified=False),indent=2))
(output/'executed_driver.py').write_text(code)
print('PHAT_BOUNDARY_DIAGNOSIS_CONFIRMED')
