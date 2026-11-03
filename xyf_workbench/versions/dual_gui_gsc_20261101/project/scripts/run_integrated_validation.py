"""Repeatable M4/M5 full arithmetic, stress, recovery and interface validation."""
from pathlib import Path
import argparse,json,os,re,subprocess,time
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--tag',default='m5_validation');a=p.parse_args()
O=R/'build/zynq12_integrated_plan'/a.tag;O.mkdir(parents=True,exist_ok=False)
S=O/'safety';results=[]
def run(name,args,env=None):
    started=time.time()
    with (O/(name+'.log')).open('w') as f:q=subprocess.run(args,cwd=R,stdout=f,stderr=subprocess.STDOUT,env=env)
    item={'test':name,'exit_code':q.returncode,'elapsed_seconds':time.time()-started,'status':'PASS' if q.returncode==0 else 'FAIL'}
    results.append(item);(O/'runs.json').write_text(json.dumps(results,indent=2));print(item,flush=True)
    assert q.returncode==0,(O/(name+'.log')).read_text()[-2000:]
def safety(name,extra,env=None,build=False):
    run(name,['python3','scripts/check_localizer12_safety.py','--output',str(S),'--report-name',name,
              *([] if build else ['--reuse-model']),*extra],env)
safety('smoke4',['--windows','4'],build=True)
for name,phase,d in [('recovery_gap','gap',0),('recovery_raw_halt','raw',700000),('recovery_srp_halt','srp',700000)]:
    safety(name,['--kind','recover','--phase',phase,'--duration',str(d),'--windows','4'])
env=os.environ.copy();env['AUTO_RECOVERY']='1'
safety('automatic_recovery',['--kind','recover','--phase','gap','--windows','4'],env)
env=os.environ.copy();env['GSC_STRESS']='1'
safety('gsc_backpressure',['--windows','8'],env)
G=R/'build/zynq12_integrated_plan/m1_release'
for k in range(4):
    env=os.environ.copy();env.update(ACOUSTIC_PCM=str(G/f'pcm_{k}.bin'),ACOUSTIC_LUT=str(G/'lut.hex'))
    safety(f'physical{k}',['--windows','1'],env)
    log=(S/f'normal_fft_0_w0_o0_n1_s20261015_b0.log').read_text()
    # Individual scenario filenames are shared by the legacy harness; preserve each replay.
    (O/f'physical{k}_rtl.log').write_text(log)
env.update(INTEGRATED_DIRECTION='1',ACOUSTIC_STEER=str(G/'steer_lut.hex'),ACOUSTIC_COMP_EXPECTED=str(G/'comp_expected.hex'))
safety('physical_link',['--windows','8'],env)
safety('physical_link_halt',['--windows','8','--kind','halt','--phase','srp','--duration','5000','--target','3'],env)
safety('normal256',['--windows','256'])
long_log=(O/'extended4096_driver.log').open('w')
long_run=subprocess.Popen(['python3','scripts/run_localizer_long.py','--model',str(S),'--output',str(O/'extended4096')],cwd=R,stdout=long_log,stderr=subprocess.STDOUT)
safety('normal1024',['--windows','1024'])
safety('matrix183',['--matrix','--jobs','3'])
safety('seed2',['--windows','8','--seed','9173'])
safety('sample_wrap',['--windows','8','--seq-base','4294966200'])
run('rv32_regression',['python3','scripts/check_rv32_mem_regression.py','--output',str(O/'rv32')])
run('memory76',['python3','scripts/check_rv32_mem_perf.py','--output',str(O/'memory')])
run('mmio8',['python3','scripts/check_rv32_mem_perf.py','--mmio-unrolled','--output',str(O/'mmio')])
run('strict_acceptance',['python3','scripts/test_overlap50_strict.py'])
run('dtcm_probe',['python3','scripts/check_localizer12_safety.py','--dtcm-probe','--kind','mem','--phase','raw','--duration','50000','--windows','4','--output',str(O/'dtcm'),'--report-name','dtcm50000'])
assert long_run.wait()==0,'Extended replay failed; see extended4096_driver.log'
long_log.close()
print('INTEGRATED_VALIDATION_PASS',flush=True)
