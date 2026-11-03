"""Focused existing CPU/PS/FFT/SIMD/capture regressions against current RTL."""
from pathlib import Path
import subprocess,json,argparse,re
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=R/'build/rv32_mem_perf/regression');a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=True)
files=list((R/'rtl').rglob('*.v'));results=[]
for top in ('tb_rv32_soc','tb_rv32_ps','tb_rv32_units','tb_vec_unit','tb_fft_bfly','tb_fft_ifft','tb_pdm_capture','tb_srp_regs','tb_srp_throughput'):
 tb=R/'tb'/(top+'.v')
 if not tb.exists():
  results.append({'test':top,'status':'NOT_FOUND'});continue
 adapted=O/(top+'.v')
 adapted.write_text(re.sub(r'\$dumpfile\("[^"]+"\)',f'$dumpfile("{O/top}.vcd")',tb.read_text()))
 tb=adapted
 compile=subprocess.run(['iverilog','-g2005' if top=='tb_rv32_ps' else '-g2012','-I',str(R/'rtl'),'-s',top,'-o',str(O/(top+'.vvp')),*map(str,files),str(tb)],cwd=R,capture_output=True,text=True)
 (O/(top+'_compile.log')).write_text(compile.stdout+compile.stderr)
 if compile.returncode:results.append({'test':top,'status':'COMPILE_FAIL'});continue
 p=subprocess.run(['vvp',str(O/(top+'.vvp'))],cwd=R,capture_output=True,text=True,errors='replace')
 text=p.stdout+p.stderr;(O/(top+'.log')).write_text(text)
 status='PASS' if p.returncode==0 and ('PASS' in text or 'pass' in text) and 'FAIL' not in text and 'ERROR' not in text else 'FAIL'
 results.append({'test':top,'status':status});print(top,status,text[-180:])
(O/'summary.json').write_text(json.dumps(results,indent=2))
assert all(r['status']=='PASS' for r in results),results
print('RV32_MEM_REGRESSION_PASS')
