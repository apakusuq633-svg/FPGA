"""Real PS application loop with host MMIO/lwIP; actual RTL frontend vectors."""
from pathlib import Path
import argparse,hashlib,json,struct,subprocess,sys
import numpy as np
from pdm12_calibration import parse_json,validate,calibration_luts
from gsc12_golden import frontend,nlms
R=Path(__file__).resolve().parents[1];sys.path.insert(0,str(R/'pc'))
from pdm_stream_receive import Statistics
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
p.add_argument('--profile',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
def run(cmd,name,marker=None):
 q=subprocess.run(list(map(str,cmd)),cwd=R,capture_output=True,text=True)
 (O/(name+'.log')).write_text(q.stdout+q.stderr)
 assert q.returncode==0,(name,q.stdout[-2500:],q.stderr[-2500:])
 if marker:assert marker in q.stdout,(name,q.stdout)
 return q.stdout
run(['python3','scripts/generate_ps_gsc_profile.py','--config',a.profile,'--fir','build/fw_fir_coeff.hex',
     '--output',O/'pdm_profile.h','--allow-test'],'profile')
v=validate(parse_json(a.profile.read_text()),True);_,steer=calibration_luts(parse_json(a.profile.read_text()),True)
tau=steer[:,7].astype(np.int32);tau[tau>=8192]-=16384
delay=((tau-tau.min())*4096).astype(np.uint32)
raw=np.random.default_rng(9173).integers(-6000,6001,(256,12),dtype=np.int16)
fir=np.array([int(t,16) for t in (R/'build/fw_fir_coeff.hex').read_text().split()],np.uint16).view(np.int16)
np.savetxt(O/'pcm.hex',raw.reshape(-1).astype(np.uint16),fmt='%04x')
np.savetxt(O/'delay.hex',delay,fmt='%08x');np.savetxt(O/'fir.hex',fir.astype(np.uint16),fmt='%04x')
bench=(R/'tb/tb_gsc12_frontend.v').read_text().replace('VECTOR_DIR',O.as_posix()).replace('OUTPUT_FILE',(O/'packets.hex').as_posix())
(O/'tb.v').write_text(bench)
run(['iverilog','-g2012','-Irtl','-s','tb_gsc12_frontend','-o',O/'rtl',*sorted((R/'rtl').rglob('*.v')),O/'tb.v'],'rtl_compile')
run(['vvp',O/'rtl'],'rtl_run','GSC12_FRONTEND_RTL_PASS')
packets=b''.join(int(line,16).to_bytes(64,'little') for line in (O/'packets.hex').read_text().split())
assert len(packets)==256*64;(O/'packets.bin').write_bytes(packets)
w=np.frombuffer(packets,dtype='<u4').reshape(-1,16)
das,beam,refs=frontend(raw,delay,fir,integrate_refs=True)
assert np.array_equal(w[:,7],das.astype(np.uint16).astype(np.uint32)|(beam.astype(np.uint16).astype(np.uint32)<<16))
expected,_,_=nlms(beam,refs)
headers=['xparameters.h','xil_io.h','xil_cache.h','xil_printf.h','xil_exception.h','xscugic.h','xemacps.h',
         'lwip/init.h','lwip/udp.h','lwip/etharp.h','netif/xadapter.h','netif/xemacpsif.h']
for name in headers:
 f=O/'include'/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text('#include "ps_stream_mock.h"\n')
sources=[R/'sw/ps_stream_udp.c',R/'sw/pdm_stream.c',R/'sw/gsc12.c',R/'sw/pdm12_calibration.c',
         R/'scripts/ps_stream_app_mock.c',R/'scripts/ps_stream_mock.h',Path(__file__),R/'scripts/generate_ps_gsc_profile.py']
(O/'sources.json').write_text(json.dumps({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2))
rows=[]
for active,fault,total in [(0,0,256),(0,1,256),(1,0,256),(0,0,100000)]:
 tag=f'gsc{active}_fault{fault}_n{total}';exe=O/tag
 run(['gcc','-std=c11','-Wall','-Wextra','-Werror','-O2','-no-pie','-fsanitize=undefined','-fno-sanitize-recover=all',
      '-DPDM_STREAM_HOST_TEST=1',*(['-DPDM_GSC_PROFILE=1','-DPDM_ENABLE_GSC=1'] if active else []),
      '-I'+str(O/'include'),'-I'+str(O),'-Iscripts','-Isw','scripts/ps_stream_app_mock.c',
      'sw/pdm_stream.c','sw/gsc12.c','sw/pdm12_calibration.c',
      '-Wl,--defsym=__dma_ring_start=0x08000000','-Wl,--defsym=__dma_ring_end=0x08080000','-o',exe],tag+'_compile')
 output=run([exe,O/'packets.bin',O/(tag+'.udp'),fault,total],tag,'PS_STREAM_APP_MOCK_PASS')
 blob=(O/(tag+'.udp')).read_bytes();offset=0;receiver=Statistics();frames=[];sessions=set()
 while offset<len(blob):
  length=struct.unpack_from('<I',blob,offset)[0];offset+=4
  sessions.add(struct.unpack_from('<I',blob,offset+8)[0])
  frames+=receiver.ingest(blob[offset:offset+length]);offset+=length
 assert offset==len(blob) and receiver.counts['invalid_datagrams']==0,dict(receiver.counts)
 if not fault:
  assert len(frames)==total
  actual=np.array([f['gsc'] for f in frames],np.int16)
  # The long transport case repeats the real 256-frame fixture; it is not a
  # claim that the RTL frontend was simulated continuously for 100000 frames.
  reference=expected if active else beam[np.arange(total)%256]
  assert np.array_equal(actual,reference)
  assert receiver.counts['gsc_active_frames']==(128 if active else 0),dict(receiver.counts)
 else:
  assert 0<len(frames)<255 and len(sessions)==2
  assert receiver.counts['gsc_active_frames']==0
 rows.append(dict(mode=tag,status='PASS',application_summary=output.strip(),receiver=dict(receiver.counts),frames=len(frames)))
(O/'metrics.json').write_text(json.dumps(dict(status='PASS_APPLICATION_MOCK',hardware='DEFERRED_HARDWARE',
 real_application_loop=True,real_rtl_frontend=True,cases=rows),indent=2))
print('PS_STREAM_APPLICATION_PASS',[(r['mode'],r['frames']) for r in rows])
