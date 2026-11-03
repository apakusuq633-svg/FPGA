"""PDM pins through CIC/window/custom ISA; approved test geometry through PS GSC.
No microphone hardware or ARM runtime latency is inferred from this simulation.
"""
import ctypes as C
from fractions import Fraction
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from build_circular9 import plane_wave_delays

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/circular9_e2e'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/'results.json').unlink(missing_ok=True)
    env=os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH'];env['MAKE']='mingw32-make';env['PYTHONUTF8']='1'
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
    delays=plane_wave_delays(c,16.5,22.5)
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
        '#include "circular9_candidates.h"\n'
        'size_t state_size(void){return sizeof(circular9_audio);}\n'
        'unsigned reason(void *p){return ((circular9_audio*)p)->reason;}\n'
        'unsigned align_errors(void *p){return ((circular9_audio*)p)->adaptive.stats[GSC9_ALIGN_ERRORS];}\n'
        'unsigned beam(void *p){return gsc9_model_beam(&((circular9_audio*)p)->adaptive);}\n'
        'int fine_delays(const uint32_t *lut,unsigned grid,int32_t az,int32_t el,uint32_t *out){'
        'c9_candidate c={.grid=grid,.score=1,.azimuth_mdeg=az,.elevation_mdeg=el,'
        '.flags=C9_CANDIDATE_REFINED,.uncertainty_mdeg=1000};'
        'return c9_candidate_delays_q16(&c,lut,out);}\n')
    run('ps_compile',['gcc','-shared','-O2','-Wall','-Wextra','-Werror','-Wno-unused-function','-Isw',
        'sw/circular9_audio.c','sw/circular9_candidates.c','sw/gsc9.c',bridge,'-lm','-o',OUT/'ps.dll'])
    dllpath=os.add_dll_directory('C:/msys64/ucrt64/bin')
    lib=C.CDLL(str(OUT/'ps.dll'));lib.state_size.restype=C.c_size_t
    state=C.create_string_buffer(lib.state_size());lib.circular9_audio_init.argtypes=[C.c_void_p];lib.circular9_audio_init(state)
    lib.circular9_audio_push.argtypes=[C.c_void_p,C.POINTER(C.c_uint32),C.POINTER(C.c_uint32),C.POINTER(C.c_uint32),C.c_int,C.c_int,C.c_uint32,C.POINTER(C.c_int16)]
    lib.reason.argtypes=[C.c_void_p];lib.align_errors.argtypes=[C.c_void_p]
    lib.beam.argtypes=[C.c_void_p];lib.beam.restype=C.c_uint32
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
    # The continuous target is converted by real PS code, independently checked
    # by exact rational interpolation, then written through the actual SoC PS
    # indexed control port. Never force internal delay or trust registers.
    direction=(ROOT/'sw/circular9_direction.h').read_text()
    azimuth=[int(v) for v in re.search(r'c9_direction_azimuth_mdeg\[32\]=\{([^}]+)',direction)[1].split(',')]
    elevation=[int(v) for v in re.search(r'c9_direction_elevation_mdeg\[32\]=\{([^}]+)',direction)[1].split(',')]
    fine_grid=800;fine_az=azimuth[fine_grid%32]+1500;fine_el=elevation[fine_grid//32]-1700
    lib.fine_delays.argtypes=[C.POINTER(C.c_uint32),C.c_uint,C.c_int32,C.c_int32,C.POINTER(C.c_uint32)]
    def checked_fine_delays(az,el):
        delays=(C.c_uint32*9)()
        assert lib.fine_delays(lut,fine_grid,az,el,delays)==1
        x=next((i for i in range(31) if az<=azimuth[i+1]),30)
        y=next((i for i in range(31) if el<=elevation[i+1]),30)
        fx=Fraction(az-azimuth[x],azimuth[x+1]-azimuth[x])
        fy=Fraction(el-elevation[y],elevation[y+1]-elevation[y])
        signed=lambda value:(value&16383)-16384 if value&8192 else value&16383
        q=[]
        for ch in range(9):
            corner=lambda dx,dy:signed(lut[ch*1024+(y+dy)*32+x+dx])
            exact=(1-fy)*((1-fx)*corner(0,0)+fx*corner(1,0))+fy*((1-fx)*corner(0,1)+fx*corner(1,1))
            q.append(exact.numerator//exact.denominator)
        expected=[(value-min(q))*4096 for value in q]
        assert list(delays)==expected
        return delays
    fine_delays=checked_fine_delays(fine_az,fine_el)
    fine_az2=azimuth[fine_grid%32]+2100;fine_el2=elevation[fine_grid//32]-1000
    fine_delays2=checked_fine_delays(fine_az2,fine_el2)
    assert list(fine_delays2)!=list(fine_delays)
    fine_delay_path=OUT/'fine_delays.hex'
    fine_delay_path.write_text(''.join(f'{value:08x}\n' for value in [*fine_delays,*fine_delays2]))
    fine_dump=OUT/'fine_packets.hex'
    run('fine_direction',[*approved_base,'+FW='+(ROOT/'build/circular9/fw_test').as_posix(),'+CASE=3',
        '+CONFIRMED_TEST_ONLY','+FINE_TEST','+FINE_DELAYS='+fine_delay_path.as_posix(),
        '+GSC_DUMP='+fine_dump.as_posix()], 'FINE_SOC_PASS')
    fine_state=C.create_string_buffer(lib.state_size());lib.circular9_audio_init(fine_state)
    lib.circular9_audio_store_direction.argtypes=[C.c_void_p,C.c_uint32,C.c_uint32,C.c_uint,C.POINTER(C.c_uint32)]
    assert lib.circular9_audio_store_direction(fine_state,0x80000001,0,fine_grid,fine_delays)==1
    assert lib.circular9_audio_store_direction(fine_state,0x80000002,0,fine_grid,fine_delays2)==1
    fine_packets=fine_trusted=fine_active=fine_blocks=0;fine_group=max(fine_delays)+65536
    fine_trusted2=fine_active2=restored_packets=restored_active=0;fine_group2=max(fine_delays2)+65536
    first_fine_trusted=first_fine_active=None
    for line in fine_dump.read_text().split():
        w=(C.c_uint32*16).from_buffer_copy(int(line,16).to_bytes(64,'little'))
        result=lib.circular9_audio_push(fine_state,w,lut,fir,1,1,0,C.byref(output));assert result>=0
        fine_packets+=1;fine_blocks+=result
        # Freeze adaptation to isolate PL/PS steering/FIR identity, including
        # transition and untrusted packets returning their original FIR.
        assert output.value==C.c_int16(w[7]>>16).value
        if w[2]==0x80000001 and w[6]&3==1:
            fine_trusted+=1
            if first_fine_trusted is None:first_fine_trusted=int(w[1])
            assert w[5]==fine_group and (w[6]>>8)&1023==fine_grid and w[14]==0
            if lib.reason(fine_state)==0:
                fine_active+=1
                if first_fine_active is None:first_fine_active=int(w[1])
                assert lib.beam(fine_state)==w[7]
        if w[2]==0x80000002 and w[6]&3==1:
            fine_trusted2+=1
            assert w[5]==fine_group2 and (w[6]>>8)&1023==fine_grid and w[14]==0
            if lib.reason(fine_state)==0:
                fine_active2+=1
                assert lib.beam(fine_state)==w[7]
        if fine_trusted2 and not w[2]&0x80000000 and w[6]&3==1:
            restored_packets+=1
            if lib.reason(fine_state)==0:
                restored_active+=1
                assert lib.beam(fine_state)==w[7]
    assert fine_trusted>1024 and fine_active>512 and fine_blocks>=3 and lib.align_errors(fine_state)==0,(
        fine_trusted,fine_active,fine_blocks,lib.align_errors(fine_state))
    assert fine_trusted2>1024 and fine_active2>512 and restored_packets>1024 and restored_active>512,(
        fine_trusted2,fine_active2,restored_packets,restored_active)
    results={'status':'PASS_DIGITAL','hardware_tested':False,'ps_execution':'native C, not timed Cortex-A9',
        'scan_model':c['scan_model'],
        'firmware_sha256':hashlib.sha256((ROOT/'build/circular9/fw/itcm.hex').read_bytes()).hexdigest(),
        'fixture_firmware_sha256':hashlib.sha256((ROOT/'build/circular9/fw_test/itcm.hex').read_bytes()).hexdigest(),
        'lut_sha256':{name:hashlib.sha256((ROOT/'build/circular9'/name).read_bytes()).hexdigest()
                      for name in ['srp_lut.hex','steer_lut.hex']},
        'pdm_first_pcm_ms':frames[0]['first_input']/40000,'pdm_start_to_first_candidate_ms':frames[0]['tick']/40000,
        'first_pcm_to_rv32_ms':[v/40000 for v in latency],
        'ps_gsc_packets':packets,'ps_gsc_active_samples':active,'ps_audio_blocks':blocks,
        'hop_samples':c['localizer_hop'],'hop_ms':c['localizer_hop']/c['sample_rate_hz']*1000,
        'approved_fixture_first_trusted_sample':first_trusted,'approved_fixture_first_active_gsc_sample':first_active,
        'gsc_warmup_after_first_trusted_ms':(first_active-first_trusted)/c['sample_rate_hz']*1000,
        'ps_alignment_errors':0,'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sorted((ROOT/'rtl').rglob('*.v')),ROOT/'configs/circular9_array.json',ROOT/'scripts/build_circular9.py',ROOT/'sw/fw/fw_planar8.c',ROOT/'tb/tb_circular9_latency.v',ROOT/'sw/circular9_audio.c',ROOT/'sw/gsc9.c',Path(__file__)]}}
    results['fine_soc_to_ps']={'status':'PASS_DIGITAL','grid':fine_grid,'azimuth_mdeg':fine_az,'elevation_mdeg':fine_el,
        'version':0x80000001,'epoch':0,'delay_q16':list(fine_delays),'group_delay_q16':fine_group,
        'packets':fine_packets,'trusted_packets':fine_trusted,'active_samples':fine_active,'audio_blocks':fine_blocks,
        'first_trusted_sample':first_fine_trusted,'first_active_sample':first_fine_active,
        'second_fine':{'version':0x80000002,'azimuth_mdeg':fine_az2,'elevation_mdeg':fine_el2,'delay_q16':list(fine_delays2),
                       'trusted_packets':fine_trusted2,'active_samples':fine_active2},
        'same_grid_coarse_restored':True,'restored_coarse_packets':restored_packets,'restored_coarse_active_samples':restored_active,
        'alignment_errors':0,'adaptation_frozen_for_alignment_proof':True,
        'fixture':'synthetic confirmed geometry; real PS candidate LUT interpolation, indexed PS shadow commit/readback, actual SoC fine delays/raw tap, real native PS fine cache and GSC; no hardware timing claim',
        'packet_sha256':hashlib.sha256(fine_dump.read_bytes()).hexdigest()}
    for source in ['sw/circular9_audio.h','sw/gsc9.h','sw/circular9_candidates.c','sw/circular9_candidates.h','sw/circular9_diagnosis.h',
                   'sw/circular9_direction.h','sw/circular9_profile.h','sw/circular9_decimator.h',
                   'sw/ps_das_audio.h','sw/das_audio_contract.h']:
        results['source_sha256'][source]=hashlib.sha256((ROOT/source).read_bytes()).hexdigest()
    for source in sorted((ROOT/'rtl').rglob('*.vh')):
        results['source_sha256'][str(source.relative_to(ROOT))]=hashlib.sha256(source.read_bytes()).hexdigest()
    (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('CIRCULAR9_PDM_RV32_PS_GSC_PASS board=UNVERIFIED',flush=True)

if __name__=='__main__':main()
