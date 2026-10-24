"""PDM pins through CIC/window/custom ISA; approved test geometry through PS GSC.
No microphone hardware or ARM runtime latency is inferred from this simulation.
"""
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/circular9_e2e'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH'];env['MAKE']='mingw32-make'
    def run(name,cmd,marker=None):
        with (OUT/(name+'.log')).open('w') as f:q=subprocess.run(list(map(str,cmd)),cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        log=(OUT/(name+'.log')).read_text(errors='replace')
        if q.returncode or (marker and marker not in log):raise RuntimeError(name+'\n'+log[-4000:])
        print(name+': PASS',flush=True);return log
    run('fixture',[sys.executable,'scripts/build_circular9.py','--test-geometry'],'CIRCULAR9_BUILD_PASS')
    model=OUT/'model'
    run('soc_compile',['C:/msys64/usr/bin/perl.exe','C:/msys64/ucrt64/bin/verilator','--binary','--timing','-Wno-fatal','-j','4',
        '-CFLAGS','-D_GLIBCXX_USE_CXX11_ABI=0','-LDFLAGS','-static-libstdc++ -static-libgcc',
        '--top-module','tb_circular9_latency','-Irtl','--Mdir',model,*sorted((ROOT/'rtl').rglob('*.v')),ROOT/'tb/tb_circular9_latency.v'])
    c=json.loads((ROOT/'configs/circular9_array.json').read_text())
    delays=[math.dist((.08,.12,.3),m)/343*c['sample_rate_hz'] for m in c['channel_positions_m']]
    bits=[0]*65536
    # One independent sigma-delta accumulator per physical microphone.
    for ch,d in enumerate(delays):
        error=0.0
        for n in range(65536):
            x=.006*sum(math.sin(2*math.pi*k*(n/c['pdm_decimation']-d)/1024+k*.173) for k in range(14,53,3))
            y=1 if error>=0 else -1;error+=x-y
            if y>0:bits[n]|=1<<ch
    pdm=OUT/'pdm.hex';pdm.write_text(''.join(f'{v:03x}\n' for v in bits))
    base=[model/'Vtb_circular9_latency.exe','+PRODUCTION','+WINDOWS=8','+PCM='+(ROOT/'build/circular9_checks/pcm.hex').as_posix()]
    log=run('pdm_to_result',[*base,'+FW='+(ROOT/'build/circular9/fw').as_posix(),'+PDM='+pdm.as_posix()], 'CIRCULAR9_LATENCY_PASS')
    frames=[{k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)} for line in log.splitlines() if line.startswith('FRAME ')]
    latency=[int(v) for v in re.findall(r'first_pcm_to_rv32=(\d+)',log)]
    assert len(latency)==8 and max(latency)<400000
    dump=OUT/'approved_packets.hex'
    approved_base=[arg if str(arg)!='+WINDOWS=8' else '+WINDOWS=20' for arg in base]
    run('approved_direction',[*approved_base,'+FW='+(ROOT/'build/circular9/fw_test').as_posix(),'+CASE=3',
        '+CONFIRMED_TEST_ONLY','+GSC_DUMP='+dump.as_posix()], 'CIRCULAR9_LATENCY_PASS')
    bridge=OUT/'bridge.c'
    bridge.write_text('#include "circular9_audio.h"\n'
        'size_t state_size(void){return sizeof(circular9_audio);}\n'
        'unsigned reason(void *p){return ((circular9_audio*)p)->reason;}\n'
        'unsigned align_errors(void *p){return ((circular9_audio*)p)->adaptive.stats[GSC9_ALIGN_ERRORS];}\n')
    run('ps_compile',['gcc','-shared','-O2','-Wall','-Wextra','-Werror','-Wno-unused-function','-Isw',
        'sw/circular9_audio.c','sw/gsc9.c',bridge,'-o',OUT/'ps.dll'])
    dllpath=os.add_dll_directory('C:/msys64/ucrt64/bin')
    lib=C.CDLL(str(OUT/'ps.dll'));lib.state_size.restype=C.c_size_t
    state=C.create_string_buffer(lib.state_size());lib.circular9_audio_init.argtypes=[C.c_void_p];lib.circular9_audio_init(state)
    lib.circular9_audio_push.argtypes=[C.c_void_p,C.POINTER(C.c_uint32),C.POINTER(C.c_uint32),C.POINTER(C.c_uint32),C.c_int,C.c_int,C.c_uint32,C.POINTER(C.c_int16)]
    lib.reason.argtypes=[C.c_void_p];lib.align_errors.argtypes=[C.c_void_p]
    lut=(C.c_uint32*9216)(*[int(v,16) for v in (ROOT/'build/circular9/steer_lut.hex').read_text().split()])
    fir=(C.c_uint32*32)(32767,*([0]*31));output=C.c_int16();active=0;packets=0;blocks=0
    first_trusted=None;first_active=None
    for line in dump.read_text().split():
        data=int(line,16).to_bytes(64,'little');w=(C.c_uint32*16).from_buffer_copy(data)
        result=lib.circular9_audio_push(state,w,lut,fir,1,0,0,C.byref(output));assert result>=0
        if w[6]&1 and first_trusted is None:first_trusted=int(w[1])
        if lib.reason(state)==0 and first_active is None:first_active=int(w[1])
        packets+=1;blocks+=result;active+=lib.reason(state)==0
    assert active>512 and blocks>=4 and lib.align_errors(state)==0,(active,blocks,lib.align_errors(state))
    results={'status':'PASS_DIGITAL','hardware_tested':False,'ps_execution':'native C, not timed Cortex-A9',
        'pdm_first_pcm_ms':frames[0]['first_input']/40000,'pdm_start_to_first_candidate_ms':frames[0]['tick']/40000,
        'first_pcm_to_rv32_ms':[v/40000 for v in latency],
        'ps_gsc_packets':packets,'ps_gsc_active_samples':active,'ps_audio_blocks':blocks,
        'hop_samples':c['localizer_hop'],'hop_ms':c['localizer_hop']/c['sample_rate_hz']*1000,
        'approved_fixture_first_trusted_sample':first_trusted,'approved_fixture_first_active_gsc_sample':first_active,
        'gsc_warmup_after_first_trusted_ms':(first_active-first_trusted)/c['sample_rate_hz']*1000,
        'ps_alignment_errors':0,'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sorted((ROOT/'rtl').rglob('*.v')),ROOT/'tb/tb_circular9_latency.v',ROOT/'sw/circular9_audio.c',ROOT/'sw/gsc9.c',Path(__file__)]}}
    (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('CIRCULAR9_PDM_RV32_PS_GSC_PASS board=UNVERIFIED',flush=True)

if __name__=='__main__':main()
