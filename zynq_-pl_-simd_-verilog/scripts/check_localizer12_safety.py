"""RAW lifecycle audit and nonperiodic full-SoC stress; all outputs are isolated."""
from pathlib import Path
import argparse,concurrent.futures,csv,hashlib,json,re,subprocess,shutil
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('--windows',type=int,default=4);p.add_argument('--seed',type=int,default=20261015)
p.add_argument('--kind',choices=['normal','halt','mem','op','mixed','burst','gap','recover'],default='normal')
p.add_argument('--phase',default='fft');p.add_argument('--duration',type=int,default=0)
p.add_argument('--target',type=int,default=0);p.add_argument('--offset',type=int,default=0)
p.add_argument('--output',type=Path,default=R/'build/localizer12_safety/current')
p.add_argument('--reuse-model',action='store_true');p.add_argument('--matrix',action='store_true')
p.add_argument('--jobs',type=int,default=4)
p.add_argument('--report-name',default='strict');p.add_argument('--seq-base',type=int,default=0)
p.add_argument('--refine',action='store_true')
p.add_argument('--realtime-refine',action='store_true',help='Fixed publication phase boundary at a later window')
p.add_argument('--only-group',help='Refine a specific kind/phase, preserving other measured groups')
p.add_argument('--dtcm-probe',action='store_true',help='Separate scheduler with checked DTCM reads/writes')
p.add_argument('--rtl-overlay',type=Path,help='Isolated SRP/localizer RAM mapping experiment')
a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=True)
def run(cmd,log):
 with log.open('w') as f:q=subprocess.run(list(map(str,cmd)),cwd=R,stdout=f,stderr=subprocess.STDOUT)
 if q.returncode:raise RuntimeError(str(log)+'\n'+log.read_text()[-2200:])
return_paths=[*sorted((R/'rtl').rglob('*.v')),*sorted((R/'rtl').rglob('*.vh')),*sorted((R/'rtl').rglob('*.hex'))]
sources={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in return_paths}
sources.update({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [R/'scripts/localizer12_safety.cpp',R/'scripts/localizer12_safety_oracle.h',R/'tb/tb_localizer12_safety.v']})
oracle_files=[R/'sw/fw'/f'{name}.c' for name in ('fw_fft','fw_gcc','fw_tables')]
oracle_sources={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in oracle_files}
M=O/'model';G=O/'instrumented';G.mkdir(exist_ok=True)
# Simulation-only fabric gates, absent from product RTL. Both sink and producer see the same acceptance.
soc=(R/'rtl/soc/rv32_soc.v').read_text().replace('input         clk_i,','input safety_op_block,input safety_mem_block,\n  input         clk_i,',1)
assert 'input safety_op_block' in soc
soc=soc.replace('.dmem_ready_i   (dmem_ready)', '.dmem_ready_i   (dmem_ready&&!safety_mem_block)')
soc=soc.replace('.transfer_enable_i(localizer_enable),.transfer_request_i', '.safety_op_block(safety_op_block),.transfer_enable_i(localizer_enable),.transfer_request_i')
# Stop acknowledgements at the fabric as well as the CPU to preserve write acceptance semantics.
soc=soc.replace('assign dmem_ready   = ', 'assign dmem_ready   = !safety_mem_block && ')
soc=soc.replace('!safety_mem_block && dmem_mmio ? mmio_ack_q : scratch_sel ? scratch_ready : dtcm_ready;', '!safety_mem_block && (dmem_mmio ? mmio_ack_q : scratch_sel ? scratch_ready : dtcm_ready);')
core=(R/'rtl/core/rv32_core.v').read_text().replace('input         clk_i,','input safety_op_block,\n  input         clk_i,',1)
core=core.replace('transfer_fft_start_i&&fft_hw_ready','transfer_fft_start_i&&!safety_op_block&&fft_hw_ready').replace('transfer_ac_start_i&&ac_hw_ready','transfer_ac_start_i&&!safety_op_block&&ac_hw_ready')
core=core.replace('assign transfer_fft_ready_o=fft_hw_ready','assign transfer_fft_ready_o=!safety_op_block&&fft_hw_ready').replace('assign transfer_ac_ready_o=ac_hw_ready','assign transfer_ac_ready_o=!safety_op_block&&ac_hw_ready')
(G/'rv32_soc.v').write_text(soc);(G/'rv32_core.v').write_text(core)
files=[G/f.name if f.name in ('rv32_soc.v','rv32_core.v') else f for f in sorted((R/'rtl').rglob('*.v'))]
if a.rtl_overlay:
 overlay=a.rtl_overlay.resolve()
 for f in overlay.glob('*.v'):
  assert f.name in ['rv32_srp_scan.v','rv32_overlap_localizer.v'],f
  files=[f if old.name==f.name else old for old in files]
  sources[str(f.relative_to(R))]=hashlib.sha256(f.read_bytes()).hexdigest()
files+=[R/'tb/tb_localizer12_safety.v',R/'scripts/localizer12_safety.cpp']
build_root=O
# Every run owns its firmware and wrapper, including ordinary non-probe runs.
wrapper=G/'tb_localizer12_safety.v'
wrapper.write_text((R/'tb/tb_localizer12_safety.v').read_text().replace('build/localizer12_safety/fw/',str(O/'fw')+'/'))
if a.rtl_overlay and 'g_banked' in (overlay/'rv32_srp_scan.v').read_text():
 text=wrapper.read_text()
 prefix='dut.u_srp.u_scan.'
 old=prefix+'lut_mem[debug_addr]'
 assert text.count(old)==1
 expr='(debug_addr<32768?'+prefix+'g_banked.lut_lo[debug_addr[14:0]]:debug_addr<65536?'+prefix+'g_banked.lut_mid[debug_addr[14:0]]:'+prefix+'g_banked.lut_tail[debug_addr[10:0]])'
 wrapper.write_text(text.replace(old,expr))
files=[wrapper if f.name=='tb_localizer12_safety.v' else f for f in files]
extra_fw=[]
if a.dtcm_probe:
 build_root=O
 probe=G/'fw_localizer12_probe.c'
 s=(R/'sw/fw/fw_localizer12.c').read_text().replace('uint32_t id=LOC(2),kind=', 'uint32_t probe=REG(0x2a00u,0);REG(0x2a00u,0)=probe+1u;\n        if(REG(0x2a00u,0)!=probe+1u)__asm__ volatile(".word 0":::"memory");\n        uint32_t id=LOC(2),kind=')
 probe.write_text(s);extra_fw=['--transfer-source',str(probe)]
 wrapper=G/'tb_localizer12_safety.v'
 s=(R/'tb/tb_localizer12_safety.v').read_text().replace('build/localizer12_safety/fw/',str(O/'fw')+'/')
 s=s.replace('output enabled,done,','output dtcm_request,output enabled,done,')
 s=s.replace('endmodule','assign dtcm_request=dut.dmem_req&&!dut.dmem_mmio;\nendmodule')
 s=s.replace('endmodule','''reg[31:0]dtcm_requests=0,dtcm_blocked=0,dtcm_accepts=0;
 always @(posedge clk)if(rst_n&&dut.dmem_req&&!dut.dmem_mmio)begin
  dtcm_requests<=dtcm_requests+1;
  if(mem_block)dtcm_blocked<=dtcm_blocked+1;
  if(dut.dmem_ready)dtcm_accepts<=dtcm_accepts+1;
 end
 final begin $display("DTCM_PROBE requests=%0d blocked=%0d accepts=%0d",dtcm_requests,dtcm_blocked,dtcm_accepts);end
endmodule''')
 wrapper.write_text(s);files=[wrapper if f.name=='tb_localizer12_safety.v' else f for f in files]
 # Arm at the requested pipeline phase, but start a RAM wait only when a real
 # non-MMIO request is present. Poll-loop layout must not turn this into MMIO-only stress.
 probe_cpp=G/'localizer12_safety.cpp'
 cpp=(R/'scripts/localizer12_safety.cpp').read_text()
 needle='if(!inject&&produced>=1024&&received==target&&phase_match(phase,top.transfer_state,top.channel,top.n,top.raw_pass)){'
 assert needle in cpp
 cpp=cpp.replace('bool inject=false;','bool dtcm_armed=false;bool inject=false;')
 cpp=cpp.replace(needle,'if(!inject&&produced>=1024&&received==target&&phase_match(phase,top.transfer_state,top.channel,top.n,top.raw_pass))dtcm_armed=true;\n  if(!inject&&produced>=1024&&received==target&&(kind=="mem"?(dtcm_armed&&top.dtcm_request):phase_match(phase,top.transfer_state,top.channel,top.n,top.raw_pass))){')
 probe_cpp.write_text(cpp);files=[probe_cpp if f.name=='localizer12_safety.cpp' else f for f in files]
 sources['test_dtcm_probe']=hashlib.sha256(probe.read_bytes()+wrapper.read_bytes()+probe_cpp.read_bytes()).hexdigest()
if not a.reuse_model:
 run(['python3','scripts/build_live12.py','--transfer','--windows','0','--hot-o2','--output',build_root,*extra_fw],O/'firmware_build.log')
 for name in ('fw_fft','fw_gcc','fw_tables'):
  run(['gcc','-O2','-DFW_SIMD_PHAT_MODEL=1','-DFW_GCC_AUDIT=1','-c',R/'sw/fw'/f'{name}.c','-o',G/f'{name}.o'],O/f'{name}_compile.log')
 run(['verilator','-Wno-fatal','-DLOCALIZER_PCM_TEST','--cc','--exe','--build','-j','4','--top-module','tb_localizer12_safety','-Irtl','--Mdir',M,
      '--output-split','20000','--output-split-cfuncs','500','-CFLAGS',f'-O2 -DFW_GCC_AUDIT=1 -I{R}/sw/fw -I{R}/scripts',
      '-LDFLAGS',' '.join(str(G/f'{name}.o') for name in ('fw_fft','fw_gcc','fw_tables')),*files],O/'compile.log')
 (O/'sources.json').write_text(json.dumps(sources,indent=2))
else:
 assert json.loads((O/'sources.json').read_text())==sources,'Source changed: rebuild model'
 previous=json.loads((O/'manifest.json').read_text())
 assert previous['test_only_instrumented']=={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in G.glob('*.v')},'Test fabric gates changed: rebuild model'
 if 'oracle_sources' in previous:assert previous['oracle_sources']==oracle_sources,'Host oracle changed: rebuild model'
 else:assert subprocess.run(['git','-c','core.autocrlf=true','diff','--quiet',previous['head'],'--',*oracle_sources],cwd=R).returncode==0,'Legacy oracle source differs from its recorded HEAD'
manifest=dict(sources=sources,seed=a.seed,head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),
              scope='SOC_NONPERIODIC_PCM_TEST_GEOMETRY_ONLY',simulator=subprocess.check_output(['verilator','--version'],text=True).strip(),
              test_only_instrumented={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in G.glob('*.v')})
manifest['seed']='per_scenario_json'
manifest['oracle_sources']=oracle_sources
(O/'manifest.json').write_text(json.dumps(manifest,indent=2))
source_manifest_sha=hashlib.sha256((O/'sources.json').read_bytes()).hexdigest()
firmware_sha=hashlib.sha256((O/'fw/fw_live12.elf').read_bytes()).hexdigest()
cases=[(a.kind,a.phase,a.duration,a.target,a.offset,a.windows)]
if a.matrix:
 cases=[('normal','fft',0,0,0,4),('gap','raw',0,0,0,4),('burst','fft',0,0,0,8)]
 for kind,phases in [('halt',['before','raw','rawlate','fft','gcc','phat','ifft','srp','publish']),('mem',['raw','fft','gcc','ifft','srp','publish']),('op',['fftin','gccin','ifftin'])]:
  for phase in phases:
   for d in [0,5000,10000,50000,100000,150000,200000,300000,500000,700000]:cases.append((kind,phase,d,0,0,4))
def case(c):
 kind,phase,duration,target,offset,windows=c
 tag=f'{kind}_{phase}_{duration}_w{target}_o{offset}_n{windows}_s{a.seed}_b{a.seq_base}';log=O/(tag+'.log')
 trace=O/(a.report_name+'__'+tag+'_raw.csv') if not a.matrix and not a.refine and not a.realtime_refine else Path('-')
 with log.open('w') as f:q=subprocess.run([str(M/'Vtb_localizer12_safety'),str(windows),kind,phase,str(duration),str(a.seed),str(target),str(offset),str(trace),str(a.seq_base)],cwd=R,stdout=f,stderr=subprocess.STDOUT)
 archived=O/(a.report_name+'__'+tag+'.log')
 shutil.copyfile(log,archived)
 log=archived
 text=log.read_text();match=re.search(r'^SAFETY_SUMMARY (.+)$',text,re.M)
 result=dict(kind=kind,phase=phase,duration=duration,target=target,offset=offset,requested_windows=windows,seed=a.seed,seq_base=a.seq_base,log=str(log.relative_to(R)),exit_code=q.returncode)
 result.update(source_manifest_sha256=source_manifest_sha,firmware_sha256=firmware_sha)
 if match:
  result.update({k:int(v) if v.isdigit() else v for k,v in re.findall(r'(\w+)=(\S+)',match[1])})
  if result['status']=='PASS' and q.returncode!=0:result['status']='ERROR'
  if result['status']=='EXPLICIT_LOSS' and q.returncode!=2:result['status']='ERROR'
 else:result.update(status='ERROR',failure=text.splitlines()[-1] if text else 'EMPTY_LOG')
 if a.dtcm_probe:
  probe=re.search(r'DTCM_PROBE requests=(\d+) blocked=(\d+) accepts=(\d+)',text)
  if not probe or int(probe[3])==0 or (kind=='mem' and duration>0 and int(probe[2])==0):result.update(status='ERROR',failure='DTCM_STALL_NOT_EXERCISED')
  else:result.update(dtcm_requests=int(probe[1]),dtcm_blocked=int(probe[2]),dtcm_accepts=int(probe[3]))
 events=[dict((k,int(v)) for k,v in re.findall(r'(\w+)=(\d+)',line)) for line in text.splitlines() if line.startswith('SAFETY_WINDOW ')]
 if events:
  result['max_gap']=max(e['gap'] for e in events)
  result['fixed_phase']=all(e['latency']==393217 and (not e['gap'] or e['gap']==524288) for e in events)
  result['strict_deadline']=all(e['latency']<=524288 and e['gap']<=524288 for e in events)
  if result.get('status')=='PASS' and not result['strict_deadline']:result['status']='CORRECT_LATE'
 (O/(tag+'.json')).write_text(json.dumps(result,indent=2))
 (O/(a.report_name+'__'+tag+'.json')).write_text(json.dumps(result,indent=2))
 print(f"SAFETY_CASE {tag} {result['status']}",flush=True);return result
with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
 if a.refine or a.realtime_refine:
  groups=[('halt',x) for x in ['before','raw','rawlate','fft','gcc','phat','ifft','srp','publish']]+[('mem',x) for x in ['raw','fft','gcc','ifft','srp','publish']]+[('op',x) for x in ['fftin','gccin','ifftin']]
  if a.only_group:groups=[g for g in groups if '/'.join(g)==a.only_group];assert groups
  results=[];bounds={g:([200000,300000] if g[1] in ('publish','before') else [50000,100000]) if a.realtime_refine else ([300000,500000] if g[1]=='publish' else [200000,300000]) for g in groups}
  def accepted(item):return item.get('fixed_phase',False) if a.realtime_refine else item['status'] in ('PASS','CORRECT_LATE')
  for g in groups:
   k,ph=g
   for which in (0,1):
    while True:
     d=bounds[g][which];item=case((k,ph,d,2 if a.realtime_refine else 0,0,6 if a.realtime_refine else 4));results.append(item)
     if item['status']=='ERROR':raise RuntimeError('Unsafe bracket endpoint: '+str(item))
     if accepted(item)==(which==0):break
     if which==0:
      assert d>0;bounds[g][0]=0
     else:bounds[g][1]=max(d+1,d*2)
  # Each phase has its own bracket; adjacent-cycle and shifted phase tests follow.
  for step in range(18):
   todo=[(k,ph,(lo+hi)//2,2 if a.realtime_refine else 0,0,6 if a.realtime_refine else 4) for (k,ph),(lo,hi) in bounds.items() if hi-lo>1]
   batch=list(pool.map(case,todo));results+=batch
   for item in batch:
    g=(item['kind'],item['phase']);d=item['duration']
    if a.realtime_refine and item['status']!='ERROR':
     bounds[g][0 if item.get('fixed_phase',False) else 1]=d
    elif item['status'] in ('PASS','CORRECT_LATE'):bounds[g][0]=d
    elif item['status']=='EXPLICIT_LOSS':bounds[g][1]=d
    else:raise RuntimeError('Refinement found a real failure: '+str(item))
  edge=[]
  for (k,ph),(lo,hi) in bounds.items():
   for d in sorted(set([lo-1,lo,hi,hi+1])):edge.append((k,ph,d,2 if a.realtime_refine else 0,0,6 if a.realtime_refine else 4))
   for target,offset in ([(2,1),(2,31),(4,0),(4,7)] if a.realtime_refine else [(0,1),(0,31),(2,0),(2,7)]):edge.append((k,ph,lo,target,offset,8 if target==4 else 6))
  results+=list(pool.map(case,edge))
  labels=('last_fixed_phase','first_not_fixed_phase') if a.realtime_refine else ('last_pass','first_explicit_loss')
  bracket_file=O/('realtime_boundary_brackets.json' if a.realtime_refine else 'boundary_brackets.json')
  brackets=json.loads(bracket_file.read_text()) if a.only_group and bracket_file.exists() else {}
  brackets.update({k+'/'+ph:dict(zip(labels,[lo,hi])) for (k,ph),(lo,hi) in bounds.items()})
  (O/(a.report_name+'_brackets.json')).write_text(json.dumps({k+'/'+ph:dict(zip(labels,[lo,hi])) for (k,ph),(lo,hi) in bounds.items()},indent=2))
  bracket_file.write_text(json.dumps(brackets,indent=2))
 else:results=list(pool.map(case,cases))
keys=sorted(set().union(*(r.keys() for r in results)))
with (O/(a.report_name+'_scenarios.csv')).open('w',newline='') as f:
 w=csv.DictWriter(f,fieldnames=keys);w.writeheader();w.writerows(results)
summary=dict(status='FAIL' if any(r['status']=='ERROR' for r in results) else 'PASS',scenarios=len(results),results=results)
(O/(a.report_name+'_summary.json')).write_text(json.dumps(summary,indent=2))
print('LOCALIZER12_SAFETY_'+summary['status'],flush=True)
raise SystemExit(summary['status']!='PASS')
