"""Digital evidence for proposed geometry, masking, packing and 9/36 SoC scheduling."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import subprocess
from build_circular9 import geometry, plane_wave_delays

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/circular9_checks'


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--soc', action='store_true')
    p.add_argument('--windows', type=int, default=32)
    p.add_argument('--compare-post', action='store_true')
    a = p.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = 'C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH']
    env['MAKE'] = 'mingw32-make'
    results = {'hardware_tested': False, 'tests': {}}
    def run(name, cmd, marker=None):
        with (OUT/(name+'.log')).open('w', encoding='utf-8') as f:
            q = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
        log = (OUT/(name+'.log')).read_text(encoding='utf-8', errors='replace')
        if q.returncode or (marker and marker not in log):
            raise RuntimeError(name+'\n'+log[-5000:])
        results['tests'][name] = {'passed':True,'log_sha256':hashlib.sha256(log.encode()).hexdigest()}
        print(name+': PASS', flush=True)
        return log
    c = json.loads((ROOT/'configs/circular9_array.json').read_text())
    srp, steer, pairs = geometry(c)
    assert len(srp)==36864 and len(steer)==9216 and len(set(pairs))==36
    # Independent plane-wave projection, decoded signed LUT including center pairs.
    # A grid cell denotes an angle; there is deliberately no source range here.
    for g in [0,31,496,511,512,527,992,1023]:
        az=math.radians(-90+180*((g%32)+.5)/32)
        el=math.radians(-90+180*((g//32)+.5)/32)
        point=(math.sin(az)*math.cos(el),math.sin(el),math.cos(az)*math.cos(el))
        for k,(i,j) in enumerate(pairs):
            delays=[]
            for ch in [i,j]:
                x,y,z=c['channel_positions_m'][ch]
                delays.append(-(point[0]*x+point[1]*y+point[2]*z)/343*c['sample_rate_hz'])
            q=srp[k*1024+g];q=q-c['r_len']*16 if q>=c['r_len']*8 else q
            assert abs(q/16-(delays[0]-delays[1]))<=1/16+1e-10
    # Schema negative controls must fail rather than silently becoming ten microphones.
    for key,value in [('channels',10),('capture_slots',9),('pairs',45),('active_mask',1023)]:
        bad=dict(c);bad[key]=value
        try: geometry(bad)
        except ValueError: pass
        else: raise AssertionError('invalid profile accepted: '+key)
    results['tests']['geometry']={'passed':True,'comparisons':8*36,'negative_controls':4}
    sources=[ROOT/'rtl/array'/n for n in ['rv32_pdm_capture.v','rv32_overlap_localizer.v',
        'rv32_pdm_array_rx.v','rv32_pdm_clkgen.v','rv32_pdm_cic.v']]
    sources += [ROOT/'rtl/beamformer/rv32_das_stream.v', ROOT/'tb/tb_circular9_units.v']
    run('units_compile',['iverilog','-g2012','-Irtl','-s','tb_circular9_units','-o',OUT/'units.vvp',*sources])
    run('units',['vvp',OUT/'units.vvp'],'CIRCULAR9_UNITS_PASS')
    if a.soc:
        model=OUT/'model'
        all_rtl=sorted((ROOT/'rtl').rglob('*.v'))
        run('soc_compile',['C:/msys64/usr/bin/perl.exe','C:/msys64/ucrt64/bin/verilator',
            '--binary','--timing','-Wno-fatal','-j','4','-CFLAGS','-D_GLIBCXX_USE_CXX11_ABI=0',
            '-LDFLAGS','-static-libstdc++ -static-libgcc','--top-module','tb_circular9_latency',
            '-Irtl','--Mdir',model,*all_rtl,ROOT/'tb/tb_circular9_latency.v'])
        rng=random.Random(20261022)
        tones=[(k,rng.random()*2*math.pi) for k in range(14,53,2)]
        # One broadband plane-wave source at known angles; no spherical-distance fixture.
        delays=plane_wave_delays(c,16.5,22.5)
        samples=[int(100*sum(math.sin(2*math.pi*k*(n-d)/1024+phase) for k,phase in tones))&65535
                 for n in range(4096) for d in delays]
        pcm=OUT/'pcm.hex';pcm.write_text(''.join(f'{v:04x}\n' for v in samples))
        for name,case,windows in [('continuous',0,a.windows),('silent',1,3),('clipped',2,3),('unverified_geometry',3,3),('snapshot_resume',4,3)]:
            dump=OUT/(name+'_fast');dump.mkdir(exist_ok=True)
            log=run(name,[model/'Vtb_circular9_latency.exe','+PRODUCTION',
                '+FW='+str(ROOT/'build/circular9/fw').replace('\\','/'),
                '+PCM='+str(pcm).replace('\\','/'),'+WINDOWS='+str(windows),'+CASE='+str(case),
                '+DUMP='+dump.as_posix()],'CIRCULAR9_LATENCY_PASS')
            rows=[{k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)} for line in log.splitlines() if line.startswith('FRAME ')]
            results['tests'][name]['frames']=rows
            observed=[{k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
                      for line in log.splitlines() if line.startswith('WINDOW_LATENCY ')]
            results['tests'][name]['window_latency']=observed
            # Snapshot mode deliberately suspends capture; its post-resume
            # reference anchor is checked separately by the RTL testbench.
            if case!=4:assert observed and max(x['first_pcm_to_rv32'] for x in observed)<400000
            if case==0:
                # Independent input-domain statistics for every overlapping window.
                def words(path):
                    return [int(w,16) for line in path.read_text().splitlines()
                            for w in line.split('//')[0].split() if not w.startswith('@')]
                for frame,row in enumerate(rows,1):
                    expected=[]
                    for ch in range(9):
                        values=[samples[((row['first_sample']+n)%4096)*9+ch] for n in range(1024)]
                        values=[v-65536 if v>=32768 else v for v in values]
                        energy=sum(v*v for v in values)
                        expected.extend([sum(values)&0xffffffff,energy&0xffffffff,energy>>32,
                                         max(abs(v) for v in values),sum(v in (-32768,32767) for v in values)])
                    assert words(dump/f'statistics_{frame}.hex')==expected,(frame,'acquisition statistics')
                assert all(b['first_sample']-a0['first_sample']==c['localizer_hop'] for a0,b in zip(rows,rows[1:]))
                results['latency']={'clock_hz':40000000,'sample_rate_hz':c['sample_rate_hz'],
                    'window_samples':1024,'hop_samples':c['localizer_hop'],
                    'window_budget_ms':1024/c['sample_rate_hz']*1000,'hop_ms':c['localizer_hop']/c['sample_rate_hz']*1000,
                    'first_aligned_pcm_to_even_rv32_publication_ms_min':min(x['first_pcm_to_rv32'] for x in observed)/40000,
                    'first_aligned_pcm_to_even_rv32_publication_ms_max':max(x['first_pcm_to_rv32'] for x in observed)/40000,
                    'after_last_pcm_to_even_publication_ms_max':max(x['first_pcm_to_rv32']-x['acquisition_span'] for x in observed)/40000,
                    'firmware_internal_post_acquisition_ms_max':max(x['post_acquisition'] for x in observed)/40000,
                    'capture_drops':sum(x['capture_drop'] for x in rows),'audio_drops':sum(x['audio_drop'] for x in rows),
                    'ps_receipt_measured':False,'physical_geometry_confirmed':False}
            if a.compare_post:
                ref=OUT/(name+'_reference');ref.mkdir(exist_ok=True)
                old=run(name+'_reference',[model/'Vtb_circular9_latency.exe','+PRODUCTION',
                    '+FW='+str(ROOT/'build/circular9/fw_reference').replace('\\','/'),
                    '+PCM='+pcm.as_posix(),'+WINDOWS='+str(windows),'+CASE='+str(case),
                    '+DUMP='+ref.as_posix()],'CIRCULAR9_LATENCY_PASS')
                old_rows=[{k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)} for line in old.splitlines() if line.startswith('FRAME ')]
                for frame,(fast,slow) in enumerate(zip(rows,old_rows),1):
                    assert fast['reason']==slow['reason']
                    assert fast['compute']<slow['compute']
                    # Faster postprocessing changes the requested snapshot time;
                    # after resume these are different input windows, not a map-equivalence test.
                    if case!=4 or frame==1:
                        for field in ['scores','statistics']:
                            assert (dump/f'{field}_{frame}.hex').read_bytes()==(ref/f'{field}_{frame}.hex').read_bytes()
                assert len(rows)==len(old_rows)==windows
                results['tests'][name]['reference_frames']=old_rows
                results['tests'][name]['bit_exact_maps_and_statistics_windows']=1 if case==4 else windows
        hold=run('diagnosis_hold',[model/'Vtb_circular9_latency.exe','+PRODUCTION',
            '+CONFIRMED_TEST_ONLY','+FW='+str(ROOT/'build/circular9/fw_test').replace('\\','/'),
            '+PCM='+pcm.as_posix(),'+WINDOWS=10','+CASE=5'],'CIRCULAR9_LATENCY_PASS')
        results['tests']['diagnosis_hold']['test_fixture_only']=True
        results['tests']['diagnosis_hold']['fixture_firmware_sha256']=hashlib.sha256(
            (ROOT/'build/circular9/fw_test/itcm.hex').read_bytes()).hexdigest()
        results['tests']['diagnosis_hold']['covered']='D3 hold, D1 selected candidate, D3 clear previous target'
        results['firmware_sha256']=hashlib.sha256((ROOT/'build/circular9/fw/itcm.hex').read_bytes()).hexdigest()
    deps=[*sorted((ROOT/'rtl').rglob('*.v')),ROOT/'tb/tb_circular9_units.v',ROOT/'tb/tb_circular9_latency.v',Path(__file__)]
    results['sources']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in deps}
    (OUT/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('CIRCULAR9_DIGITAL_PASS hardware=UNVERIFIED',flush=True)


if __name__=='__main__':main()
