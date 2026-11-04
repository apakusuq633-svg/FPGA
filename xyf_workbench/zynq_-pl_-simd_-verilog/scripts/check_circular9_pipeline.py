"""Execute real CPU0/CPU1 task orchestration using named native device doubles."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/circular9_pipeline_checks'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    include = OUT/'include'
    include.mkdir(exist_ok=True)
    (include/'xil_cache.h').write_text('/* Native test supplies instrumented cache doubles before task header. */\n')
    (include/'xil_printf.h').write_text('void xil_printf(const char *, ...);\n')
    env = os.environ.copy()
    env['PATH'] = 'C:/msys64/ucrt64/bin;C:/msys64/usr/bin;' + env['PATH']
    commands = [
        ['gcc','-std=c11','-O2','-Wall','-Wextra','-Werror','-DC9_CANDIDATES_TEST','-Wno-unused-const-variable','-Wno-unused-function','-Wno-unused-variable',
         '-I'+str(include),'-Isw','sw/circular9_candidates.c','sw/circular9_diagnosis.c',
         'sw/circular9_pipeline_test.c','-pthread','-lm','-o',str(OUT/'pipeline.exe')],
        [str(OUT/'pipeline.exe'),str(OUT/'candidates.json')],
    ]
    for name,command in zip(['compile','native'],commands):
        result=subprocess.run(command,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (OUT/(name+'.log')).write_text(result.stdout)
        print(result.stdout,end='',flush=True)
        if result.returncode:
            raise RuntimeError(name+' failed')
    document=json.loads((OUT/'candidates.json').read_text())
    assert len(document['candidates'])==3
    assert document['model_validated']==0
    assert document['feature_contract']==0x43394632
    assert document['separation_contract']==0x43395333
    assert document['candidate_map_period_ms']==20
    assert document['proposal_updates']>=51
    scheduler=document['diagnostic_scheduler']
    assert scheduler['hop_raw_samples']==80000 and scheduler['hop_ms']==512 and scheduler['latest_only']
    assert scheduler['history_frames']>=4*156250 and scheduler['history_bytes']==33554432
    auxiliary=document['auxiliary_search']
    assert auxiliary['hop_raw_samples']==8192 and auxiliary['window_raw_samples']==16640
    assert auxiliary['max_age_raw_samples']==31250 and auxiliary['no_CPU0_FFT']
    assert auxiliary['accepted']>=1 and auxiliary['cpu1_completed']>=1
    assert all(c['diagnosis']['label']=='unknown' and not c['diagnosis']['fault_direction_valid'] for c in document['candidates'])
    assert len({c['diagnosis']['binding']['first_sample'] for c in document['candidates']})==1
    assert all(len(c['diagnosis']['features'])==18 for c in document['candidates'])
    assert all(c['diagnosis']['feature_contract']==0x43394632 for c in document['candidates'])
    for candidate in document['candidates']:
        extraction=candidate['diagnosis']['extraction']
        assert extraction['status']==1
        assert extraction['fft_count']==1 and extraction['fft_size']==4096
        assert extraction['envelope_samples']==2500
        assert abs(extraction['observation_seconds']-1.024)<1e-9
        assert extraction['bin_spacing_hz']<.6
        assert 1.4<extraction['hann_enbw_hz']<1.5
    log=(OUT/'native.log').read_text()
    assert 'CIRCULAR9_PIPELINE_PASS' in log
    line=next(s for s in log.splitlines() if s.startswith('PS_PIPELINE_PASS'))
    metrics={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
    assert metrics['coasting_frames']==2 and metrics['recovery_frames']==3
    assert metrics['recovered_jobs']==1 and metrics['proposal_rejected']>=2
    assert metrics['refined_angle_guard']==1
    scheduler_line=next(s for s in log.splitlines() if s.startswith('SCHEDULER_PIPELINE_PASS'))
    auxiliary_line=next(s for s in log.splitlines() if s.startswith('AUXILIARY_PIPELINE_PASS'))
    assert 'queued_and_compute_deadline_rejected=1' in scheduler_line
    assert 'replay_wrong_era_expired_rejected=7' in auxiliary_line
    sources=['sw/ps_circular9_tasks.h','sw/ps_circular9_api.h','sw/circular9_tracking.h',
             'sw/circular9_candidates.c','sw/circular9_candidates.h','sw/circular9_diagnosis.c',
             'sw/circular9_diagnosis.h','sw/circular9_pipeline_test.c','sw/acoustic_circular9_image.h',
             'sw/circular9_candidates_test.c','sw/circular9_direction.h','sw/circular9_decimator.h',
             'sw/ps_ui_page.h','sw/ps_mic_levels.h','sw/ps_features.h','sw/ps_env_pipeline.h',
             'sw/circular9_proposals.h','sw/circular9_envelope.h',
             'sw/ps_circular9_aux.h','sw/circular9_schedule.h','sw/circular9_http_args.h',
             'sw/bearing_6004_2zr.h','scripts/check_circular9_pipeline.py']
    evidence={'passed':True,'hardware_tested':False,'ps_runtime_measured':False,'classifier_validated':False,
              'fixture':'native device doubles; actual three-source raw capture and separation/diagnosis; injected known primary SRP peaks at20ms; actual CPU1 multiband FFT discovery without tracks; exact512ms sample-domain overlap and latest-only overload/expiry guards; interval support/provenance negatives; synthetic confirmed geometry; native PE alignment8192 replaces ARM1MiB; no configured machine model',
              'metrics':metrics,'sources':{s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}}
    (OUT/'results.json').write_text(json.dumps(evidence,indent=2)+'\n')

if __name__=='__main__':
    main()
