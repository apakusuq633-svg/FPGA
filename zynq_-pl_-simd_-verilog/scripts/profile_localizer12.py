"""Non-product probes around the full arithmetic safety test; all math stays real."""
from pathlib import Path
import argparse,csv,hashlib,json,os,sys
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
p.add_argument('--firmware',type=Path);p.add_argument('--windows',type=int,default=8);a=p.parse_args()
output=a.output.resolve();assert not output.exists();original=R/'scripts/check_localizer12_safety.py';code=original.read_text()
ports='output profile_mmio_ack,profile_ram_req,profile_dmem_ready,profile_fetch_stall,profile_mac_valid,profile_raw_collision,profile_fft_launch,profile_ac_launch,output[31:0]profile_dmem_addr,output[2:0]profile_fft_state,output[1:0]profile_vec_state,\n input[16:0]debug_addr'
assigns='''assign profile_mmio_ack=dut.dmem_mmio&&dut.dmem_ready;
 assign profile_ram_req=dut.dmem_req&&!dut.dmem_mmio;
 assign profile_dmem_addr=dut.dmem_addr;assign profile_dmem_ready=dut.dmem_ready;
 assign profile_fetch_stall=dut.u_core.fetch_stall;
 assign profile_fft_state=dut.u_core.u_fft_bfly.state_q;
 assign profile_vec_state=dut.u_core.u_vec_unit.state_q;
 assign profile_mac_valid=dut.u_core.u_vec_unit.v3_q&&dut.u_core.u_vec_unit.op3_q==1;
 assign profile_raw_collision=dut.g_localizer.u_transfer.wr_active&&dut.g_localizer.u_transfer.state==2&&
  dut.g_localizer.u_transfer.wr_sample*6+dut.g_localizer.u_transfer.wr_word==dut.g_localizer.u_transfer.raw_addr;
 assign profile_fft_launch=dut.u_core.u_fft_bfly.run_start;
 assign profile_ac_launch=dut.u_core.u_acoustic_ext.state_q==0&&dut.u_core.u_acoustic_ext.start_i&&!dut.u_core.u_acoustic_ext.is_io_i;
'''
needle="wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))"
assert code.count(needle)==1
code=code.replace(needle,"wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace(' input[16:0]debug_addr',"+repr(ports)+").replace('endmodule',"+repr(assigns+'\nendmodule')+").replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))")
needle="files+=[R/'tb/tb_localizer12_safety.v',R/'scripts/localizer12_safety.cpp']"
replacement='''profile_cpp=G/'localizer12_profile.cpp'
profile_text=(R/'scripts/localizer12_safety.cpp').read_text()
profile_text=profile_text.replace('#include "localizer12_safety_oracle.h"', '#include "localizer12_safety_oracle.h"\\n#include "localizer12_profile.h"')
profile_text=profile_text.replace(' Vtb_localizer12_safety top;', ' Localizer12Profile profile;\\n Vtb_localizer12_safety top;')
profile_text=profile_text.replace('  if(top.rst_n){', '  profile.sample(top,cycle);\\n  if(top.rst_n){',1)
profile_text=profile_text.replace('    top.final();return loss?2:0;', '    profile.save();top.final();return loss?2:0;')
profile_cpp.write_text(profile_text)
sources[str(profile_cpp.relative_to(R))]=hashlib.sha256(profile_cpp.read_bytes()).hexdigest()
files+=[R/'tb/tb_localizer12_safety.v',profile_cpp]'''
assert code.count(needle)==1;code=code.replace(needle,replacement)
if a.firmware:
 assert code.count('extra_fw=[]')==1
 code=code.replace('extra_fw=[]',"extra_fw=['--transfer-source',"+repr(str(a.firmware.resolve()))+"]")
os.environ['M10_PROFILE_DIR']=str(output)
sys.argv=[str(original),'--output',str(output),'--windows',str(a.windows),'--report-name','profiled']
ns={'__file__':str(original),'__name__':'__main__'}
try:exec(compile(code,str(original),'exec'),ns)
except SystemExit as e:assert e.code in (0,None),e.code
inputs=[original,R/'scripts/localizer12_profile.h',Path(__file__),R/'sw/fw/fw_localizer12.c' if a.firmware is None else a.firmware.resolve()]
(output/'profile_sources.json').write_text(json.dumps({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs},indent=2))
def rows(name):return list(csv.DictReader((output/name).open()))
counters={r['name']:int(r['value']) for r in rows('profile_counters.csv')}
dispatch=[{k:int(v) for k,v in row.items()} for row in rows('profile_dispatch.csv')]
assert [r['calls'] for r in dispatch]==[12*a.windows,66*a.windows,66*a.windows,66*a.windows,a.windows],dispatch
assert counters['raw_collision']==0 and counters['simd_mac_slots']==32*counters['fir_outputs'],counters
summary=json.loads((output/'profiled_summary.json').read_text())['results'][0]
assert summary['status']=='PASS' and summary['windows']==a.windows
report=dict(status='PASS_PROFILE_FULL_ARITHMETIC',windows=a.windows,counters=counters,dispatch=dispatch,
 safety=summary,scope='Simulation-only observation; overlapping counters must not be summed as disjoint waits',
 hardware='DEFERRED_HARDWARE')
(output/'profile_metrics.json').write_text(json.dumps(report,indent=2));(output/'executed_driver.py').write_text(code)
print('LOCALIZER12_PROFILE_PASS',json.dumps(report))
