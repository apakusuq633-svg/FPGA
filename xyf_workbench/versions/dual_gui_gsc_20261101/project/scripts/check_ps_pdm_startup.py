"""Execute actual PS C main against delayed-first-frame and dead-capture MMIO mocks."""
from pathlib import Path
import argparse,subprocess,json
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--before',action='store_true');p.add_argument('--protocol',action='store_true');p.add_argument('--expect-defects',action='store_true');p.add_argument('--source',type=Path,help='Explicit archived C source for reproducible A/B protocol checks');a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
source=R/'build/pdm_convergence/baseline/ps_pdm.c' if a.before else R/'sw/ps_pdm.c'
(O/'xil_io.h').write_text('#include <stdint.h>\nuint32_t Xil_In32(uintptr_t);\nvoid Xil_Out32(uintptr_t,uint32_t);\n')
(O/'xil_printf.h').write_text('int xil_printf(const char*,...);\n')
if a.protocol:
    import hashlib
    source=a.source.resolve() if a.source else R/'sw/ps_pdm.c'
    cmd=['gcc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(O),'-DAPP_SOURCE="'+str(source)+'"',str(R/'scripts/ps_pdm_protocol_mock.c'),'-o',str(O/'protocol')]
    q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/'compile.log').write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
    cases=['normal','frame_wrap','seq_wrap','restart','refill_same_slot','max_length','dead_start','dead_bank','invalid_zero','invalid_large','changed_seq','release_refused']
    rows=[]
    for case in cases:
        command=[str(O/'protocol'),case];q=subprocess.run(command,capture_output=True,text=True,timeout=60)
        (O/(case+'.log')).write_text(q.stdout+q.stderr)
        expected=1 if a.expect_defects and case in ['invalid_zero','invalid_large','changed_seq','release_refused'] else 0
        assert q.returncode==expected,(case,q.returncode,q.stdout,q.stderr)
        rows.append(dict(case=case,command=command,returncode=q.returncode,expected=expected,summary=q.stdout.strip()))
    (O/'results.json').write_text(json.dumps(dict(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),compile=cmd,cases=rows),indent=2))
    print('PS_PDM_PROTOCOL_PASS cases=12 expected_defects='+str(a.expect_defects));raise SystemExit(0)
body=r'''
#include <stdio.h>
#include <stdint.h>
#include <string.h>
static unsigned ticks, frame_seen, rate_logged, early, seq, words, releases;
static int dead;
uint32_t Xil_In32(uintptr_t a) {
  unsigned off=(unsigned)(a-0x43c00000u); ++ticks;
  if(off==0x32c) {unsigned f=(!dead&&ticks>80)?1+(ticks-80)/8:0;if(f)frame_seen=1;return f;}
  if(off==0x304)return (!dead&&ticks>80)?1:0;
  if(off==0x334||off==0x308)return 16;
  if(off==0x310)return seq;
  if(off==0x314)return 1+16*seq;
  if(off==0x320){++words;return words*0x21917u;}
  if(off==0x300)return 3;
  if(off>=0x340&&off<0x358)return 0x40004000;
  return 0;
}
void Xil_Out32(uintptr_t a,uint32_t v){(void)v;if(a==0x43c00328u){++seq;++releases;}}
int xil_printf(const char *s,...){if(strstr(s,"FRAME_CNT advanced by")){rate_logged=1;if(!frame_seen)early=1;}return 0;}
#define main app_main
#include "SOURCE"
#undef main
int main(int argc,char **argv){(void)argv;dead=argc>1;int rc=app_main();
  if(dead){if(rc==0||rate_logged)return 3;puts("PS_PDM_DEAD_STARTUP_BOUNDED_PASS");return 0;}
  if(early){puts("PS_PDM_STARTUP_REJECTED early_measure=1");return 2;}
  if(rc||!rate_logged||releases!=3||words!=288)return 4;
  printf("PS_PDM_STARTUP_ORDER_PASS first_frame_seen=%u banks=%u words=%u\n",frame_seen,releases,words);return 0;
}
'''.replace('SOURCE',str(source))
(O/'mock.c').write_text(body)
commands=[['gcc','-std=c11','-O2','-Wall','-Wextra','-Werror','-I'+str(O),str(O/'mock.c'),'-o',str(O/'mock')],[str(O/'mock')]]
if not a.before:commands.append([str(O/'mock'),'dead'])
rows=[]
for i,cmd in enumerate(commands):
    q=subprocess.run(cmd,cwd=R,capture_output=True,text=True,timeout=60)
    (O/f'run_{i}.log').write_text(q.stdout+q.stderr)
    expected=2 if a.before and i==1 else 0
    assert q.returncode==expected,(cmd,q.returncode,q.stdout,q.stderr)
    rows.append({'command':cmd,'returncode':q.returncode,'expected':expected,'summary':q.stdout.strip()})
(O/'results.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
