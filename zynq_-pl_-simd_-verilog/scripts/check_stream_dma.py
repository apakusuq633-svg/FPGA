"""Build/replay the actual AXI DMA ring RTL against a transactional DDR model."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
files=[R/'rtl/transport/rv32_stream_dma.v',R/'rtl/soc/rv32_axi_lite_slave.v',R/'scripts/stream_dma_test.cpp']
(O/'sources.json').write_text(json.dumps({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2))
cmd=['verilator','-Wno-fatal','--cc','--exe','--build','-j','4','--top-module','rv32_stream_dma','--Mdir',str(O/'model'),'-CFLAGS','-O2',*map(str,files)]
with (O/'compile.log').open('w') as f:q=subprocess.run(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT)
assert q.returncode==0,(O/'compile.log').read_text()[-4000:]
with (O/'run.log').open('w') as f:q=subprocess.run([str(O/'model/Vrv32_stream_dma')],cwd=R,stdout=f,stderr=subprocess.STDOUT)
t=(O/'run.log').read_text();print(t,flush=True);assert q.returncode==0 and 'STREAM_DMA_PASS' in t
m=re.search(r'STREAM_DMA_PASS (.*)',t);metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',m[1])}
assert metrics['inputs']==metrics['published']+metrics['drops'] and metrics['axi_errors']==1 and metrics['timeouts']==3
(O/'metrics.json').write_text(json.dumps({'status':'PASS_RTL','hardware':'DEFERRED_HARDWARE','metrics':metrics},indent=2))
