"""Host-only O3 build in a fresh clone; verify identical cycle/numeric results."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,time
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
S=a.model.resolve();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False);M=O/'model';shutil.copytree(S/'model',M)
# Only copied object files are removed, never the authoritative model or source.
assert M.is_relative_to(R/'build/zynq12_integrated_plan')
for q in M.glob('*.o'):q.unlink()
with(O/'compile.log').open('w')as f:q=subprocess.run(['make','-f','Vtb_localizer12_safety.mk','-j4','OPT_FAST=-O3 -march=native','OPT_SLOW=-O1'],cwd=M,stdout=f,stderr=subprocess.STDOUT)
assert q.returncode==0,(O/'compile.log').read_text()[-3000:]
results=[]
for label,binary in [('reference',S/'model/Vtb_localizer12_safety'),('optimized',M/'Vtb_localizer12_safety')]:
    start=time.perf_counter()
    with(O/(label+'.log')).open('w')as f:q=subprocess.run([str(binary),'16','normal','fft','0','20261015','0','0','-','0'],cwd=R,stdout=f,stderr=subprocess.STDOUT)
    t=(O/(label+'.log')).read_text();match=re.search(r'^SAFETY_SUMMARY (.+)$',t,re.M)
    assert q.returncode==0 and match,t[-2000:]
    results.append({'label':label,'wall_seconds':time.perf_counter()-start,'summary':match[1]})
assert results[0]['summary']==results[1]['summary'],'Host compiler changed the verified result'
data={'status':'PASS','scope':'Host simulator optimization only; FPGA RTL/cycles unchanged','compiler_flags':['OPT_FAST=-O3 -march=native','OPT_SLOW=-O1'],
 'binary':str(M/'Vtb_localizer12_safety'),'binary_sha256':hashlib.sha256((M/'Vtb_localizer12_safety').read_bytes()).hexdigest(),'benchmarks':results}
(O/'metrics.json').write_text(json.dumps(data,indent=2));print(data,flush=True)
