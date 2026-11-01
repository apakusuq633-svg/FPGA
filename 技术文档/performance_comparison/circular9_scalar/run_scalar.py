"""Exact nine-mic PL localization arithmetic on scalar portable C. No board."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,struct,subprocess,sys,time
HERE=Path(__file__).resolve().parent
W=HERE.parents[1]
PROD=W/'FPGA/xyf_workbench/zynq_-pl_-simd_-verilog'
PL=HERE.parent/'pl_rtl'
ENV=os.environ.copy();ENV['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+ENV.get('PATH','');ENV['PYTHONUTF8']='1'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def words(p):
 return [int(v,16) for line in p.read_text().splitlines() for v in line.split('//')[0].split() if not v.startswith('@')]
def binary(p,fmt,values):p.write_bytes(struct.pack('<'+fmt*len(values),*values))
def run(name,cmd):
 with (HERE/(name+'.log')).open('w',encoding='utf-8') as f:
  f.write('$ '+' '.join(map(str,cmd))+'\n');f.flush();q=subprocess.run(list(map(str,cmd)),cwd=HERE,env=ENV,stdout=f,stderr=subprocess.STDOUT)
 out=(HERE/(name+'.log')).read_text(encoding='utf-8',errors='replace')
 if q.returncode:raise RuntimeError(name+' failed\n'+out[-4000:])
 return out
def main():
 p=argparse.ArgumentParser();p.add_argument('--bench',type=int,default=0);p.add_argument('--all-windows',action='store_true');a=p.parse_args()
 third=HERE/'third_party';third.mkdir(exist_ok=True)
 hashes={}
 for name in ['fw_fft.c','fw_fft.h','fw_tables.c','fw_tables.h','fw_plat.h','fw_cycle_profile.h']:
  source=PROD/'sw/fw'/name;target=third/name
  if not target.exists():shutil.copy2(source,target)
  assert source.read_bytes()==target.read_bytes()
  hashes['sw/fw/'+name]=sha(source)
 hann=words(PL/'source/rtl/rom/pdm_hann_q14.hex')
 (HERE/'hann_q14.h').write_text('#ifndef C9S_HANN_H\n#define C9S_HANN_H\n#include <stdint.h>\nstatic const int16_t c9s_hann[1024]={'+','.join(map(str,hann))+'};\n#endif\n')
 all_pcm=words(PL/'inputs/circular9_pcm.hex');raw=all_pcm[:1024*9]
 assert len(raw)==1024*9
 binary(HERE/'input.pcm','H',raw)
 lut=words(PL/'source/build/circular9/srp_lut.hex');assert len(lut)==36*1024
 packed=bytearray(C9_LUT_BYTES:=46080)
 for i,v in enumerate(lut):
  bit=i*10;v=(v&1023)<<(bit&7);packed[bit//8]|=v&255;packed[bit//8+1]|=(v>>8)&255
 (HERE/'srp_lut10.bin').write_bytes(packed)
 for path in ['rtl/array/rv32_overlap_localizer.v','rtl/acoustic/rv32_acoustic_ext.v','rtl/srp/rv32_srp_scan.v','rtl/rom/pdm_hann_q14.hex','configs/circular9_array.json']:
  hashes[path]=sha(PROD/path)
  assert (PROD/path).read_bytes()==(PL/'source'/path).read_bytes()
 for path in ['c9_scalar.c','c9_scalar.h','host_bench.c','hann_q14.h',Path(__file__).name]:hashes['experiment/'+path]=sha(HERE/path)
 (HERE/'source_hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
 exe=HERE/'c9_scalar_host.exe'
 cmd=['C:/msys64/ucrt64/bin/gcc.exe','-std=c11','-O2','-fwrapv','-fno-tree-vectorize','-fno-tree-slp-vectorize','-DFW_ACCEL=0','-Wall','-Wextra','-I'+str(third),HERE/'c9_scalar.c',HERE/'host_bench.c',third/'fw_fft.c',third/'fw_tables.c','-o',exe]
 run('host_compile',cmd)
 output=HERE/'host_output';output.mkdir(exist_ok=True)
 log=run('host_validation',[exe,HERE/'input.pcm',HERE/'srp_lut10.bin',output,0])
 checks={}
 for name,count,fmt,ref in [('statistics',45,'I','statistics_1.hex'),('spectrum',576,'I','spectrum.hex'),('scores',1024,'I','scores_1.hex')]:
  got=list(struct.unpack('<'+fmt*count,(output/(name+'.bin')).read_bytes()));expected=words(PL/'soc_dump'/ref)
  assert len(expected)==count
  bad=[{'index':i,'got':x,'expected':y} for i,(x,y) in enumerate(zip(got,expected)) if x!=y]
  checks[name]={'words':count,'mismatches':len(bad),'first_mismatches':bad[:12],'reference_sha256':sha(PL/'soc_dump'/ref)}
 corr=PL/'soc_dump/correlation_pair_major.hex'
 if corr.exists():
  got=list(struct.unpack('<'+'H'*(36*64),(output/'correlation.bin').read_bytes()));expected=words(corr)
  bad=[{'index':i,'got':x,'expected':y} for i,(x,y) in enumerate(zip(got,expected)) if x!=y]
  checks['correlation']={'words':len(got),'mismatches':len(bad),'first_mismatches':bad[:12],'reference_sha256':sha(corr)}
 else:checks['correlation']={'pending_PL_dump':True}
 result={'date':'2026-10-28','scope':'same first1024 aligned PCM samples,9 channels,36 pairs,1024 grid; portable scalar C matches current PL arithmetic; no A9/board timing','checks':checks,'pass':all(v.get('mismatches',0)==0 for v in checks.values()),'source_hash_manifest':'source_hashes.json','input_sha256':sha(HERE/'input.pcm'),'lut_packed_sha256':sha(HERE/'srp_lut10.bin'),'clock':'QueryPerformanceCounter','scalar_compiler_vectorization_disabled':True,'validation_output':log}
 (HERE/'validation.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result,indent=2),flush=True)
 if not result['pass']:raise SystemExit(1)
 if a.all_windows:
  frames=json.loads((PL/'results.json').read_text())['tests']['circular9']['frames'];windows=[]
  root=HERE/'host_windows';root.mkdir(exist_ok=True)
  for frame in frames:
   index=frame['index'];first=frame['first_sample'];dest=root/f'window_{index}';dest.mkdir(exist_ok=True)
   pcm=[all_pcm[((first+n)%4096)*9+ch] for n in range(1024) for ch in range(9)]
   binary(dest/'input.pcm','H',pcm)
   run(f'window_{index}',[exe,dest/'input.pcm',HERE/'srp_lut10.bin',dest,0])
   entry={'index':index,'first_sample':first,'checks':{}}
   for name,count,ref in [('statistics',45,f'statistics_{index}.hex'),('scores',1024,f'scores_{index}.hex')]:
    got=list(struct.unpack('<'+'I'*count,(dest/(name+'.bin')).read_bytes()));expected=words(PL/'soc_dump'/ref)
    bad=sum(x!=y for x,y in zip(got,expected));assert len(expected)==count and bad==0,(index,name,bad)
    entry['checks'][name]={'words':count,'mismatches':bad,'reference_sha256':sha(PL/'soc_dump'/ref)}
   windows.append(entry)
  proof={'pass':True,'windows':windows,'window_count':len(windows),'score_words':len(windows)*1024,'statistics_words':len(windows)*45,'PL_results_sha256':sha(PL/'results.json'),'periodic_input_frames':4096,'scope':'all actual PL first_sample windows; aligned PCM→45 statistics and1024 scores'}
  (HERE/'windows_validation.json').write_text(json.dumps(proof,indent=2)+'\n');print('ALL_WINDOWS_PASS',len(windows),flush=True)
 if a.bench:
  bench=run('host_timing',[exe,HERE/'input.pcm',HERE/'srp_lut10.bin',output,a.bench])
  rows=[{'round':int(r),'repeat':int(n),'ticks':int(t),'frequency':int(f),'per_window_ms':int(t)/int(f)/int(n)*1000} for r,n,t,f in re.findall(r'C9_SCALAR_HOST round=(\d+) repeat=(\d+) ticks=(\d+) frequency=(\d+)',bench)]
  assert len(rows)==9
  result.update(host_wall_clock=rows,measurement_type='x86_64 host scalar C wall-clock; NOT Cortex-A9 and NOT comparable directly with PL40MHz cycles')
  (HERE/'results.json').write_text(json.dumps(result,indent=2)+'\n')
  print('HOST_SCALAR_TIMING_MS',sorted(row['per_window_ms'] for row in rows),flush=True)
if __name__=='__main__':main()
