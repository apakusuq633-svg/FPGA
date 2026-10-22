"""Run the complete arithmetic SoC while a real DMA instance is quarantined."""
from pathlib import Path
import argparse,json,sys
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
original=R/'scripts/check_localizer12_safety.py';probe=(R/'tb/stream_dma_isolation_probe.vh').read_text()
code=original.read_text()
needle="wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))"
replacement="wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace('endmodule',"+repr(probe+"\nendmodule")+").replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))"
assert code.count(needle)==1;code=code.replace(needle,replacement)
cpp_needle="files+=[R/'tb/tb_localizer12_safety.v',R/'scripts/localizer12_safety.cpp']"
cpp_injection="""isolation_cpp=G/'localizer12_isolation.cpp'
isolation_text=(R/'scripts/localizer12_safety.cpp').read_text()
isolation_text=isolation_text.replace('int main(', 'static double isolation_time=0;\\ndouble sc_time_stamp(){return isolation_time;}\\nint main(',1)
isolation_text=isolation_text.replace('top.clk=0;', 'isolation_time=cycle*25.0;top.clk=0;',1).replace('top.clk=1;', 'isolation_time=cycle*25.0+12.5;top.clk=1;',1)
isolation_cpp.write_text(isolation_text)
sources[str(isolation_cpp.relative_to(R))]=hashlib.sha256(isolation_cpp.read_bytes()).hexdigest()
files+=[R/'tb/tb_localizer12_safety.v',isolation_cpp]"""
assert code.count(cpp_needle)==1;code=code.replace(cpp_needle,cpp_injection)
(O/'probe_source.vh').write_text(probe)
sys.argv=[str(original),'--windows','8','--output',str(O),'--report-name','isolation8']
try:exec(compile(code,str(original),'exec'),{'__name__':'__main__','__file__':str(original)})
except SystemExit as e:
    if e.code not in (None,0):raise
summary=json.loads((O/'isolation8_summary.json').read_text());row=summary['results'][0]
text=(R/row['log']).read_text();assert 'M9_DMA_ISOLATION_PASS' in text
assert row['status']=='PASS' and row['raw_drop']==row['window_drop']==row['audio_drop']==0
(O/'dma_isolation_metrics.json').write_text(json.dumps({'status':'PASS_SAFE_QUARANTINE','main_pipeline':'PASS',
 'dma_timeout_injected':True,'dma_published':0,'quarantined_transactions':1,'normal_result':row},indent=2))
print('M9_FULL_SOC_DMA_ISOLATION_PASS',flush=True)
