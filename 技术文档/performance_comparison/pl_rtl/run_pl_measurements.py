#!/usr/bin/env python3
"""Rebuild and measure current nine-channel PL RTL, without touching production outputs.

Run: C:/msys64/ucrt64/bin/python.exe performance_comparison/pl_rtl/run_pl_measurements.py
--reuse reuses this experiment's already-generated mirror and Verilator binaries.
All times are simulated PL clock cycles, with a 25 ns TB clock (40 MHz), not board measurements.
"""
from pathlib import Path
import argparse,csv,hashlib,importlib.util,json,math,os,random,re,shutil,struct,subprocess,sys,time
HERE=Path(__file__).resolve().parent
WORKSPACE=HERE.parents[1]
SOURCE=WORKSPACE/'FPGA/xyf_workbench/zynq_-pl_-simd_-verilog'
MIRROR=HERE/'source'
PREFIX='D:/AMDDesignTools/2025.2/gnu/riscv/nt/bin/riscv64-unknown-elf-'
ENV=os.environ.copy();ENV['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+ENV.get('PATH','');ENV['MAKE']='mingw32-make';ENV['PYTHONUTF8']='1'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(name,args,cwd=MIRROR):
    args=list(map(str,args));(HERE/'logs').mkdir(exist_ok=True)
    start=time.time()
    logfile=HERE/'logs'/f'{name}.log'
    if logfile.exists():
        n=1
        while (HERE/'logs'/f'{name}.attempt{n:02d}.log').exists():n+=1
        shutil.copy2(logfile,HERE/'logs'/f'{name}.attempt{n:02d}.log')
    with logfile.open('w',encoding='utf-8') as f:
        f.write('$ '+' '.join(args)+'\n');f.flush()
        result=subprocess.run(args,cwd=cwd,env=ENV,stdout=f,stderr=subprocess.STDOUT)
    print(f'{name}: exit={result.returncode} wall={time.time()-start:.2f}s',flush=True)
    if result.returncode:raise RuntimeError(f'{name}: see logs/{name}.log')
    return (HERE/'logs'/f'{name}.log').read_text(encoding='utf-8',errors='replace')
def write_json(path,data):
    temp=path.with_suffix(path.suffix+'.tmp');temp.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');temp.replace(path)
def rows(log,prefix):return [{k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)} for line in log.splitlines() if line.startswith(prefix+' ')]
def words(path):
    return [int(v,16) for line in path.read_text().splitlines() for v in line.split('//')[0].split() if not v.startswith('@')]
def setup():
    MIRROR.mkdir(exist_ok=True)
    for folder in ('rtl','sw/fw','configs'):
        shutil.copytree(SOURCE/folder,MIRROR/folder,dirs_exist_ok=True)
    for p in (SOURCE/'sw').glob('*.h'):
        shutil.copy2(p,MIRROR/'sw'/p.name)
    (MIRROR/'scripts').mkdir(exist_ok=True);(MIRROR/'tb').mkdir(exist_ok=True)
    for file in ('build_circular9.py','build_live16.py'):
        shutil.copy2(SOURCE/'scripts'/file,MIRROR/'scripts'/file)
    # This AMD GNU toolchain defaults to a build-id NOTE at ITCM address zero.
    # Keep .text and _start at zero, matching the existing HEX loader contract.
    build=MIRROR/'scripts/build_circular9.py'
    build.write_text(build.read_text(encoding='utf-8').replace("'-Wl,--gc-sections,-Map='","'-Wl,--build-id=none,--gc-sections,-Map='"),encoding='utf-8')
    shutil.copy2(SOURCE/'tb/tb_circular9_latency.v',MIRROR/'tb/tb_circular9_latency.v')
    # Test-driver-only monitor. No production RTL or firmware text is modified.
    tb=MIRROR/'tb/tb_circular9_latency.v';s=tb.read_text()
    s=s.replace('if(overlap && dut.localizer_enable)transfer_cycles','if(dut.localizer_enable)transfer_cycles')
    s=s.replace('if(overlap && dut.loc_done)begin','if(dut.loc_done)begin')
    s=s.replace('if(!dut.u_srp.u_scan.busy_o && srp_begin!=0)begin $display("SRP_ENGINE cycles=%0d",tick-srp_begin);srp_begin=0;end',
      'if(!dut.u_srp.u_scan.busy_o && srp_begin!=0)begin\n'
      '    $display("SRP_ENGINE cycles=%0d",tick-srp_begin);srp_begin=0;\n'
      '    $display("SRP_DONE_BOUNDARY first_sample=%0d tick=%0d raw_ready_to_scores=%0d aligned_last_pcm_to_scores=%0d",\n'
      '      dut.g_localizer.u_transfer.source_first+dut.g_localizer.u_transfer.active_first,tick,\n'
      '      dut.g_localizer.u_transfer.tick-dut.g_localizer.u_transfer.active_ready_tick,\n'
      '      tick-first_input-(dut.g_localizer.u_transfer.source_first+dut.g_localizer.u_transfer.active_first-first_input_id+1023)*PCM_TICKS);\n'
      '   end')
    # Export full first-window raw/prepared/spectral/correlation memories for traceability.
    s=s.replace('$writememh($sformatf("%s/statistics_%0d.hex",dump,frames),dut.g_localizer.u_transfer.statistics);',
      '$writememh($sformatf("%s/statistics_%0d.hex",dump,frames),dut.g_localizer.u_transfer.statistics);\n'
      '     if(frames==1)begin\n'
      '      $writememh({dump,"/raw_ring.hex"},dut.g_localizer.u_transfer.raw_mem);\n'
      '      $writememh({dump,"/spectrum.hex"},dut.g_localizer.u_transfer.spectrum);\n'
      '      $writememh({dump,"/scratch.hex"},dut.g_live16_scratch.u_ram.memory);\n'
      '      $writememh({dump,"/correlation_bank0.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[0].r_bank);\n'
      '      $writememh({dump,"/correlation_bank1.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[1].r_bank);\n'
      '      $writememh({dump,"/correlation_bank2.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[2].r_bank);\n'
      '      $writememh({dump,"/correlation_bank3.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[3].r_bank);\n'
      '     end')
    tb.write_text(s)
    shutil.copy2(HERE/'tb_pl_microbench.sv',MIRROR/'tb/tb_pl_microbench.sv')
    shutil.copy2(HERE/'microbench.c',MIRROR/'sw/fw/microbench.c')
    files=[]
    for folder in ('rtl','sw/fw','configs'):
        files += [p for p in (SOURCE/folder).rglob('*') if p.is_file()]
    files += [SOURCE/'tb/tb_circular9_latency.v',SOURCE/'scripts/build_circular9.py',SOURCE/'scripts/build_live16.py']
    files += list((SOURCE/'sw').glob('*.h'))
    write_json(HERE/'source_hashes.json',{p.relative_to(SOURCE).as_posix():sha(p) for p in sorted(files)})
def generate_input():
    (HERE/'inputs').mkdir(exist_ok=True)
    spec=importlib.util.spec_from_file_location('isolated_circular9',MIRROR/'scripts/build_circular9.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    c=json.loads((MIRROR/'configs/circular9_array.json').read_text())
    # Match the repository's physical plane-wave fixture and independent statistics reference.
    d=m.plane_wave_delays(c,16.5,22.5)
    rng=random.Random(20261022);tones=[(k,rng.random()*2*math.pi) for k in range(14,53,2)]
    samples=[int(100*sum(math.sin(2*math.pi*k*(n-delay)/1024+phase) for k,phase in tones))&65535 for n in range(4096) for delay in d]
    p=HERE/'inputs/circular9_pcm.hex';p.write_text(''.join(f'{v:04x}\n' for v in samples))
    coeff=[int(v) for v in re.search(r'fw_fir_coeff\[32\]\s*=\s*\{([^}]+)',(MIRROR/'sw/fw/fw_fir_coeff.h').read_text())[1].replace('\n','').split(',') if v.strip()]
    (HERE/'inputs/fir_coeff.hex').write_text(''.join(f'{v&65535:04x}\n' for v in coeff))
    write_json(HERE/'inputs/input_manifest.json',{'seed':20261022,'azimuth_deg':16.5,'elevation_deg':22.5,'samples_per_channel':4096,'channels':9,'tones_fft_bins':list(range(14,53,2)),'delays_samples':d,'pcm_sha256':sha(p),'fir_taps':coeff,'fir_input':'((uint32(n+1)*1103515245+12345)>>16)&65535, then minus32768','fft_input':'same LCG formula,1024 samples','physical_capture':False})
    return samples,c
def build_micro():
    out=HERE/'micro_fw';out.mkdir(exist_ok=True);objs=[]
    for file in ('start.S','microbench.c','fw_fft.c','fw_tables.c','fw_fir.c'):
        obj=out/(Path(file).stem+'.o');objs.append(obj)
        run('micro_cc_'+Path(file).stem,[PREFIX+'gcc.exe','-march=rv32im_zicsr','-mabi=ilp32','-Os','-ffreestanding','-fno-builtin','-nostdlib','-Wall','-Wextra','-Werror','-ffunction-sections','-fdata-sections','-DFW_CYCLE_PROFILE=1','-c',MIRROR/'sw/fw'/file,'-o',obj])
    elf=out/'microbench.elf'
    run('micro_link',[PREFIX+'gcc.exe','-march=rv32im_zicsr','-mabi=ilp32','-nostdlib','-T',MIRROR/'sw/fw/link_live16.ld','-Wl,--build-id=none,--gc-sections,-Map='+str(out/'microbench.map'),*objs,'-o',elf])
    check=run('micro_elf_headers',[PREFIX+'readelf.exe','-h','-S',elf]);assert re.search(r'Entry point address:\s+0x0\b',check)
    disassembly=run('micro_disassembly',[PREFIX+'objdump.exe','-d',elf])
    body=re.search(r'<fw_fir_run>:\n(.*?)(?=\n\n|\Z)',disassembly,re.S)[1]
    trace=re.findall(r'^\s*([0-9a-f]+):\s+00f80833\s+',body,re.M)
    assert len(trace)==1,'FIR ck accumulator instruction must be uniquely identified'
    write_json(out/'trace_metadata.json',{'fir_checksum_add_pc':int(trace[0],16),'instruction':'00f80833','observation':'retired ck_new-ck_previous yields each already-clipped y, without modifying function'})
    for mem,sec in [('itcm','.text'),('dtcm','.data')]:
        binary=out/(mem+'.bin');run('micro_objcopy_'+mem,[PREFIX+'objcopy.exe','-O','binary','--only-section='+sec,elf,binary]);data=binary.read_bytes();data+=b'\0'*((-len(data))%4)
        assert len(data)<=16384
        (out/(mem+'.hex')).write_text(''.join(f'{v:08x}\n' for v in struct.unpack('<'+'I'*(len(data)//4),data)))
def compile_model(top,model):
    run(top+'_compile',['C:/msys64/usr/bin/perl.exe','C:/msys64/ucrt64/bin/verilator','--binary','--timing','-Wno-fatal','-j','4','-CFLAGS','-D_GLIBCXX_USE_CXX11_ABI=0','-LDFLAGS','-static-libstdc++ -static-libgcc','--top-module',top,'-Irtl','--Mdir',model,*sorted((MIRROR/'rtl').rglob('*.v')),MIRROR/'tb'/(top+('.sv' if top=='tb_pl_microbench' else '.v'))])
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--reuse',action='store_true');ap.add_argument('--windows',type=int,default=32);ap.add_argument('--only',choices=['soc','micro','all'],default='all');a=ap.parse_args()
    HERE.mkdir(exist_ok=True)
    if not a.reuse or not MIRROR.exists():setup()
    (MIRROR/'build').mkdir(exist_ok=True)
    spec=importlib.util.spec_from_file_location('isolated_fft_tables',MIRROR/'scripts/build_live16.py');tables=importlib.util.module_from_spec(spec);spec.loader.exec_module(tables);tables.fft_rom()
    samples,c=generate_input()
    result={'date':'2026-10-28','measurement':'current-source RTL simulation; no FPGA board','pl_clock_hz':40000000,'tb_clock_period_ns':25,'source_root':str(SOURCE),'source_hash_manifest':'source_hashes.json','tests':{}}
    old=HERE/'results.json'
    if old.exists():result['tests']=json.loads(old.read_text(encoding='utf-8'))['tests']
    if a.only in ('soc','all'):
        if not a.reuse or not (MIRROR/'build/circular9/fw/itcm.hex').exists():run('build_circular9',[sys.executable,MIRROR/'scripts/build_circular9.py','--compiler-prefix',PREFIX])
        check=run('circular9_elf_headers',[PREFIX+'readelf.exe','-h','-S',MIRROR/'build/circular9/fw/fw_circular9.elf']);assert re.search(r'Entry point address:\s+0x0\b',check),'Rebuild without --reuse to remove AMD default build-id section'
        model=HERE/'soc_model'
        if not a.reuse or not (model/'Vtb_circular9_latency.exe').exists():compile_model('tb_circular9_latency',model)
        dump=HERE/'soc_dump';dump.mkdir(exist_ok=True)
        log=run('circular9_run',[model/'Vtb_circular9_latency.exe','+PRODUCTION','+FW='+str(MIRROR/'build/circular9/fw').replace('\\','/'),'+PCM='+str(HERE/'inputs/circular9_pcm.hex').replace('\\','/'),'+WINDOWS='+str(a.windows),'+CASE=0','+DUMP='+dump.as_posix()])
        assert 'CIRCULAR9_LATENCY_PASS' in log
        fs=rows(log,'FRAME');lat=rows(log,'WINDOW_LATENCY');post=rows(log,'PRODUCTION_POST')
        for frame,row in enumerate(fs,1):
            expected=[]
            for ch in range(9):
                values=[samples[((row['first_sample']+n)%4096)*9+ch] for n in range(1024)];values=[v-65536 if v>=32768 else v for v in values];energy=sum(v*v for v in values)
                expected.extend([sum(values)&0xffffffff,energy&0xffffffff,energy>>32,max(abs(v) for v in values),sum(v in (-32768,32767) for v in values)])
            assert words(dump/f'statistics_{frame}.hex')==expected
        phases=[];current=[]
        for line in log.splitlines():
            if line.startswith('TRANSFER_PHASE '):
                row={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)};current.append(row)
                if row['state']==31:phases.append(current);current=[]
        if (dump/'correlation_bank0.hex').exists():
            banks=[words(dump/f'correlation_bank{k}.hex') for k in range(4)]
            corr=[banks[pair%4][(pair//4)*64+lag] for pair in range(36) for lag in range(64)]
            (dump/'correlation_pair_major.hex').write_text(''.join(f'{v:04x}\n' for v in corr))
        groups={'prepare_statistics_window':(1,2,3,29),'fft_transfer_run':(4,5,6,7,8,30),'cross_spectrum':(9,10,11,12),'phat':(13,14,15),'inverse_transfer_run':(16,17,18,19,31),'correlation_extract':(20,21,22,23),'srp_request_wait':(24,25),'score_read':(26,27),'publish_state':(28,)}
        aggregates=[]
        for index,phase in enumerate(phases,1):
            values={r['state']:r['cycles'] for r in phase}
            aggregates.append({'window':index,**{name:sum(values[i] for i in states) for name,states in groups.items()},'idle_acquisition_and_previous_post':values[0]})
        with (HERE/'stage_cycles.csv').open('w',newline='',encoding='utf-8-sig') as f:
            w=csv.DictWriter(f,fieldnames=list(aggregates[0]));w.writeheader();w.writerows(aggregates)
        result['tests']['circular9']={'status':'PASS','windows':len(fs),'frames':fs,'window_latency':lat,'post':post,'score_completion_boundary':rows(log,'SRP_DONE_BOUNDARY'),'transfer_state_cycles_by_window':phases,'stage_aggregates':aggregates,'fft_run':rows(log,'FFT_ENGINE'),'srp_busy':rows(log,'SRP_ENGINE'),'audio':rows(log,'AUDIO'),'independent_statistics_words_checked':45*len(fs),'notes':['Aligned PCM injection, not PDM acoustic analog capture.','Each window first_sample is its own first-sample anchor; 1023 sample intervals=261888 cycles are included.','Stable even RV32 publication is the end anchor; PS receive/network excluded.','Score completion is SRP busy falling/done observed; excludes the subsequent 1024-grid best-score read and CPU postprocessing.','Raw-ready anchor is after the final PCM capture word commits; rolling statistics were accumulated during acquisition.','Geometry remains production unconfirmed; no trusted physical steering claimed.','Stage histograms count localizer transfer states; CPU postprocessing is separate.','Continuous DAS/FIR throughput runs concurrently, using testbench unity-impulse coefficients; its service time is not a measured acoustic group delay.']}
        write_json(old,result)
    if a.only in ('micro','all'):
        build_micro();model=HERE/'micro_model'
        if not a.reuse or not (model/'Vtb_pl_microbench.exe').exists():compile_model('tb_pl_microbench',model)
        dump=HERE/'micro_dump';dump.mkdir(exist_ok=True)
        trace=json.loads((HERE/'micro_fw/trace_metadata.json').read_text())
        log=run('micro_run',[model/'Vtb_pl_microbench.exe','+FW='+str(HERE/'micro_fw').replace('\\','/'),'+DUMP='+dump.as_posix(),'+FIR_TRACE_PC='+f'{trace["fir_checksum_add_pc"]:x}']);assert 'PL_MICROBENCH_PASS' in log
        r={x['index']:x['value'] for x in rows(log,'MICRO_RESULT')}
        result['tests']['fft']={'status':'PASS','scalar_cycles':r[1],'hardware_total_cycles':r[2],'speedup':r[1]/r[2],'hardware_push_cycles':r[3],'hardware_run_instruction_cycles':r[4],'hardware_pop_cycles':r[5],'mismatched_int16':r[6],'int16_checked':r[14],'engine_cycles':rows(log,'MICRO_FFT_ENGINE'),'scope':'Actual fw_fft.c scalar vs fft1024_hw, includes function and load/run/pop; input creation excluded; internal profile timestamps add small overhead.'}
        coefficient=json.loads((HERE/'inputs/input_manifest.json').read_text())['fir_taps']
        x=[((((n+1)*1103515245+12345)&0xffffffff)>>16)-32768 for n in range(512)]
        expected=[min(32767,max(-32768,sum(coefficient[k]*x[n-k] for k in range(32) if n>=k)>>15))&0xffffffff for n in range(512)]
        retired=words(dump/'fir_retired_samples.hex');assert retired[:512]==expected and retired[512:]==expected,'independent integer FIR output mismatch'
        result['tests']['fir']={'status':'PASS','scalar_cycles':r[7],'simd_cycles':r[8],'speedup':r[7]/r[8],'scalar_checksum':r[9],'scalar_weighted_checksum':r[10],'simd_checksum':r[11],'simd_weighted_checksum':r[12],'mismatched_samples':0,'samples_checked':r[15],'retired_samples_vs_independent_integer_reference':1024,'scope':'Actual unmodified fw_fir_run(0/1),512 samples32taps; includes history initialization, generation, normalization,clip and checksums; coefficient preloading excluded. Every scalar and SIMD sample is reconstructed from retirement of ck accumulation and checked independently; no function instrumentation.'}
        write_json(old,result)
    csvrows=[]
    for name in ['fft','fir']:
        if name in result['tests']:
            t=result['tests'][name];fast=t.get('hardware_total_cycles',t.get('simd_cycles'));csvrows += [{'test':name,'path':'scalar','cycles':t['scalar_cycles'],'ms_at_40mhz':t['scalar_cycles']/40000,'speedup':1},{'test':name,'path':'accelerated','cycles':fast,'ms_at_40mhz':fast/40000,'speedup':t['speedup']}]
    if 'circular9' in result['tests']:
        for r in result['tests']['circular9']['window_latency']:
            for metric in ('first_pcm_to_rv32','post_acquisition'):
                csvrows.append({'test':'circular9_window_'+str(r['frame']),'path':metric,'cycles':r[metric],'ms_at_40mhz':r[metric]/40000,'speedup':''})
    with (HERE/'summary.csv').open('w',newline='',encoding='utf-8-sig') as f:
        w=csv.DictWriter(f,fieldnames=['test','path','cycles','ms_at_40mhz','speedup']);w.writeheader();w.writerows(csvrows)
    original=json.loads((HERE/'source_hashes.json').read_text(encoding='utf-8'))
    after={name:sha(SOURCE/name) for name in original}
    changed=[name for name in original if original[name]!=after[name]]
    write_json(HERE/'production_integrity.json',{'status':'PASS' if not changed else 'FAIL','changed_production_sources':changed,'before_sha256':original,'after_sha256':after})
    assert not changed,'Production source changed during experiment'
    if 'circular9' in result['tests']:
        t=result['tests']['circular9'];assert all(len(t[name])==t['windows'] for name in ('frames','window_latency','post','score_completion_boundary','stage_aggregates','transfer_state_cycles_by_window'))
    result['validation']={'production_source_unchanged':True,'firmware_entry_zero_verified':True,'tb_clock_40mhz_actual':True,'physical_board_measurement':False,'historical_failed_attempts_excluded':True}
    write_json(old,result)
    write_json(HERE/'artifact_hashes.json',{p.relative_to(HERE).as_posix():sha(p) for folder in ('inputs','micro_fw','soc_dump','micro_dump') if (HERE/folder).exists() for p in sorted((HERE/folder).rglob('*')) if p.is_file()})
    write_json(HERE/'experiment_driver_hashes.json',{name:sha(HERE/name) for name in ('run_pl_measurements.py','microbench.c','tb_pl_microbench.sv')})
    print('Saved results.json, summary.csv and raw logs. PASS tests: '+', '.join(result['tests']),flush=True)
if __name__=='__main__':main()
