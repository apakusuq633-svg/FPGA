"""Long replay of an already-built, hash-pinned Verilator executable."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--binary',type=Path);p.add_argument('--windows',type=int,default=4096);a=p.parse_args()
R=Path(__file__).resolve().parents[1];S=a.model.resolve();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
sources=json.loads((S/'sources.json').read_text());assert all(sha(R/k)==v for k,v in sources.items())
binary=a.binary.resolve() if a.binary else S/'model/Vtb_localizer12_safety'
manifest={'sources':sources,'binary_path':str(binary),'binary_sha256':sha(binary),'firmware_sha256':sha(S/'fw/fw_live12.elf'),'windows':a.windows}
(O/'manifest.json').write_text(json.dumps(manifest,indent=2))
start=time.time()
with(O/'run.log').open('w')as f:q=subprocess.run([str(binary),str(a.windows),'normal','fft','0','20261015','0','0','-','0'],cwd=R,stdout=f,stderr=subprocess.STDOUT)
t=(O/'run.log').read_text();line=re.search(r'^SAFETY_SUMMARY (.*)$',t,re.M)
assert q.returncode==0 and line,t[-2000:]
metrics={k:int(v) if v.isdigit() else v for k,v in re.findall(r'(\w+)=(\S+)',line[1])}
assert metrics['status']=='PASS' and metrics['windows']==a.windows
assert all(sha(R/k)==v for k,v in sources.items()),'Source changed during replay'
metrics['input_duration_seconds']=metrics['produced']/39062.5;metrics['wall_seconds']=time.time()-start
(O/'metrics.json').write_text(json.dumps(metrics,indent=2));print('EXTENDED_LOCALIZER_PASS',metrics,flush=True)
