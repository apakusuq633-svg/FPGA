"""Full current nine-channel scalar C on current RV32 SoC RTL; isolated files."""
from pathlib import Path
import argparse,json,struct,subprocess,sys,re,hashlib,shutil,time
from run_scalar import HERE,PL,ENV,words,sha
PREFIX='D:/AMDDesignTools/2025.2/gnu/riscv/nt/bin/riscv64-unknown-elf-'
def run(name,args,cwd=HERE):
 start=time.perf_counter()
 with (HERE/(name+'.log')).open('w',encoding='utf-8') as f:
  f.write('$ '+' '.join(map(str,args))+'\n');f.flush();p=subprocess.run(list(map(str,args)),cwd=cwd,env=ENV,stdout=f,stderr=subprocess.STDOUT)
 print(name,'exit',p.returncode,'host_s',round(time.perf_counter()-start,3),flush=True)
 if p.returncode:raise RuntimeError(name+' failed: '+(HERE/(name+'.log')).read_text(errors='replace')[-3000:])
 return (HERE/(name+'.log')).read_text(encoding='utf-8',errors='replace')
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--profile',action='store_true');ap.add_argument('--reuse-model',action='store_true');a=ap.parse_args()
 dest=HERE/('rv_profile' if a.profile else 'rv_plain');dest.mkdir(exist_ok=True)
 objects=[]
 files=[PL/'source/sw/fw/start.S',HERE/'rv_main.c',HERE/'c9_scalar.c',HERE/'third_party/fw_fft.c',HERE/'third_party/fw_tables.c']
 for file in files:
  obj=dest/(file.stem+'.o');objects.append(obj)
  run('rv_cc_'+('profile_' if a.profile else '')+file.stem,[PREFIX+'gcc.exe','-march=rv32im_zicsr','-mabi=ilp32','-O2','-fwrapv','-ffreestanding','-fno-builtin','-nostdlib','-Wall','-Wextra','-Werror','-ffunction-sections','-fdata-sections','-DFW_ACCEL=0',*(['-DC9S_PROFILE=1'] if a.profile else []),'-I'+str(HERE),'-I'+str(HERE/'third_party'),'-c',file,'-o',obj])
 elf=dest/'scalar.elf'
 run('rv_link_'+str(a.profile),[PREFIX+'gcc.exe','-march=rv32im_zicsr','-mabi=ilp32','-nostdlib','-T',HERE/'rv_link.ld','-Wl,--build-id=none','-Wl,--gc-sections,-Map='+str(dest/'scalar.map'),*objects,'-lgcc','-o',elf])
 assert struct.unpack_from('<I',elf.read_bytes(),24)[0]==0,'entry must match ITCM reset PC0'
 sections=run('rv_sections_'+str(a.profile),[PREFIX+'objdump.exe','-h',elf])
 assert int(re.search(r'(?m)^\s*\d+\s+\.text\s+\w+\s+(\w+)',sections).group(1),16)==0,'section-only ITCM image must have text VMA0'
 for name,section in [('itcm','.text'),('dtcm','.data')]:
  binpath=dest/(name+'.bin');run('rv_objcopy_'+name+str(a.profile),[PREFIX+'objcopy.exe','-O','binary','--only-section='+section,elf,binpath]);b=binpath.read_bytes();b+=b'\0'*((-len(b))%4);assert len(b)<=16384
  (dest/(name+'.hex')).write_text(''.join(f'{v:08x}\n' for v in struct.unpack('<'+'I'*(len(b)//4),b)))
 scratch=bytearray(65536);packed=(HERE/'srp_lut10.bin').read_bytes();raw=(HERE/'input.pcm').read_bytes();scratch[:len(packed)]=packed;scratch[len(packed):len(packed)+len(raw)]=raw
 (HERE/'scratch_input.hex').write_text(''.join(f'{v:08x}\n' for v in struct.unpack('<'+'I'*16384,scratch)))
 model=HERE/'rv_model';exe=model/'Vtb_c9_scalar.exe'
 if not a.reuse_model or not exe.exists():
  run('rv_model_compile',['C:/msys64/usr/bin/perl.exe','C:/msys64/ucrt64/bin/verilator','--binary','--timing','-Wno-fatal','-j','4','-CFLAGS','-D_GLIBCXX_USE_CXX11_ABI=0','-LDFLAGS','-static-libstdc++ -static-libgcc','--top-module','tb_c9_scalar','-Irtl','--Mdir',model,*sorted((PL/'source/rtl').rglob('*.v')),HERE/'tb_c9_scalar.sv'],PL/'source')
 dump=dest/'dump';dump.mkdir(exist_ok=True)
 log=run('rv_run_'+('profile' if a.profile else 'plain'),[exe,'+FW='+dest.as_posix(),'+DUMP='+dump.as_posix(),'+SCRATCH='+(HERE/'scratch_input.hex').as_posix()],PL/'source')
 assert 'C9_SCALAR_RV_PASS' in log
 dt=words(dump/'dtcm.hex');sc=words(dump/'scratch.hex');mail=dt[0x3800//4:0x3800//4+10];work_addr=mail[2]
 dw=struct.pack('<'+'I'*len(dt),*dt);sw=struct.pack('<'+'I'*len(sc),*sc);checks={}
 for name,got in [('statistics',dw[work_addr+6404:work_addr+6584]),('spectrum',dw[work_addr+4100:work_addr+6404]),('correlation',sw[46080:46080+4608]),('scores',sw[46080+4608:46080+4608+4096])]:
  want=(HERE/'host_output'/(name+'.bin')).read_bytes();assert len(want)==len(got)
  bad=sum(x!=y for x,y in zip(got,want));checks[name]={'bytes':len(got),'mismatched_bytes':bad,'sha256':hashlib.sha256(got).hexdigest()}
  assert not bad,(name,bad)
 result={'pass':True,'kind':'current nine-mic full scalar pipeline on RV32 SoC RTL,not board','clock_hz':40000000,'tb_clock_period_ns':25,'profile_enabled':a.profile,'scalar_call_cycles':mail[1],'scalar_call_ms_at40MHz':mail[1]/40000,'best_grid':mail[3],'best_score':mail[4],'workspace_bytes':mail[5],'phase_cycles':dict(zip(['statistics_and_scaling_parameters','Hann_nine_FFT_cache','36_XSPEC_PHAT_IFFT_ring','36_by1024_SRP'],mail[6:10])),'checks_vs_host':checks,'timing_boundary':'input raw1024x9 and packed delay LUT resident in scratch; c9s_locate call through all1024 scores written; excludes preload,peak/quality/tracking/publication; includes CSR timing wrapper overhead. Profile totals include inserted per-phase timestamps; plain run is primary.','input_sha256':sha(HERE/'input.pcm'),'lut_packed_sha256':sha(HERE/'srp_lut10.bin'),'elf_sha256':sha(elf),'source_sha256':{str(p.relative_to(HERE)) if p.is_relative_to(HERE) else str(p):sha(p) for p in files+[HERE/'rv_link.ld',HERE/'tb_c9_scalar.sv',Path(__file__)]}}
 (dest/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
if __name__=='__main__':main()
