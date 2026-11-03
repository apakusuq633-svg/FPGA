"""Read-only baseline audit; writes only to a new, exclusive M0 output directory."""
from pathlib import Path
import argparse, collections, contextlib, hashlib, io, json, os, shutil, subprocess, sys
from datetime import datetime, timezone

R = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--output', required=True)
p.add_argument('--checks', action='store_true')
a = p.parse_args()
O = Path(a.output).resolve()
O.mkdir(parents=True, exist_ok=False)

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(1024*1024), b''): h.update(b)
    return h.hexdigest()

def write(name, data):
    (O/name).write_text(json.dumps(data, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')

def git(*args):
    return subprocess.check_output(['git', '-C', str(R), *args], text=True).strip()

state = {'head': git('rev-parse','HEAD'), 'status_before':git('status','--short'),
         'utc':datetime.now(timezone.utc).isoformat(), 'root':str(R),
         'tools':{x:shutil.which(x) for x in ['python3','verilator','iverilog','vvp','gcc','tclsh']}}
write('environment.json', state)
files = []
for folder in ['rtl','sw','scripts','configs','constrs','docs','tb','build','results','vivado_zynq','vivado_zynq_good']:
    for q in (R/folder).rglob('*'):
        if not q.is_file() or O == q or O in q.parents: continue
        # Freeze all source plus all existing logs, manifests and deployable artifacts.
        if folder not in ['build','results','vivado_zynq','vivado_zynq_good'] or q.suffix.lower() in ['.bit','.xsa','.elf','.log'] or 'manifest' in q.name.lower():
            files.append({'path':q.relative_to(R).as_posix(),'bytes':q.stat().st_size,'sha256':digest(q)})
write('protected_artifacts.json', files)
comparisons = []
for rel in ['build/localizer12_safety/final_implementation/source_manifest.json',
            'build/localizer12_safety/release/manifest.json',
            'build/localizer12_safety/final/manifest.json',
            'build/localizer12_safety/build_manifest.json']:
    q=R/rel
    data=json.loads(q.read_text()); sources=data.get('sources',data)
    rows=[]
    for name, expected in sources.items():
        if not isinstance(expected,str) or len(expected)!=64: continue
        src=R/name
        actual=digest(src) if src.is_file() else None
        rows.append({'path':name,'expected':expected,'actual':actual,'match':actual==expected})
    comparisons.append({'manifest':rel,'checked':len(rows),'matches':sum(x['match'] for x in rows),
                        'mismatches':[x for x in rows if not x['match']]})
write('source_manifest_comparison.json', comparisons)
evidence={}
for tag in ['release','final']:
    base=R/'build/localizer12_safety'/tag
    evidence[tag]={}
    for name in ['long1024_summary.json','baseline256_summary.json','matrix_summary.json']:
        q=base/name
        if not q.exists(): continue
        data=json.loads(q.read_text()); rows=data.get('results',[])
        evidence[tag][name]={'status':data.get('status'),'count':len(rows),
             'outcomes':dict(collections.Counter(x['status'] for x in rows)),
             'missing_logs':[x.get('log') for x in rows if not (R/x.get('log','MISSING')).is_file()]}
        if len(rows)==1: evidence[tag][name]['metrics']=rows[0]
write('historical_evidence_review.json',evidence)
anchors={
 'rtl/soc/rv32_soc.v':['parameter DAS_ACTIVE','parameter ACOU_LANES','u_beam','pdm_aligned','u_transfer','u_srp','u_steer'],
 'rtl/array/rv32_overlap_localizer.v':['raw_mem','window_primed','failed','source_gap','raw_overrun','I_PUSH:','pair==65','PUBLISH:'],
 'rtl/beamformer/rv32_das_stream.v':['history','correction','average12','snap[m]','input_drop','fifo_drop','EMIT:'],
 'rtl/core/rv32_core.v':['audio_ready_o','audio_result_o','A_PUSH:','A_RED','retire_valid_o','memwb'],
 'rtl/vec/rv32_vec_unit.v':['LANES ='],
 'rtl/srp/rv32_steer_regs.v':['comp','locked'],
 'scripts/create_zynq_project.tcl':['set part','set fclk','apply_pdm_constraints'],
 'sw/fw/fw_localizer12.c':['TEST_GEOMETRY_ONLY','case 1:','case 5:','LOC(6)'],
 'configs/production_array.json':['mic_xyz','channel_to_mic','physical_mapping'],
 'scripts/gen_pdm12_test_srp.py':['coords=','for el','delay=']}
with (O/'source_anchors.txt').open('w',encoding='utf-8') as f:
    for rel, needles in anchors.items():
        for n,line in enumerate((R/rel).read_text(encoding='utf-8').splitlines(),1):
            if any(x in line for x in needles):f.write(f'{rel}:{n}: {line}\n')
checks=[]
if a.checks:
    sys.path.insert(0,str(R/'scripts'))
    os.chdir(R)
    # Run existing checks with only their output-directory expressions redirected.
    for script, old, new in [
      ('check_pdm12_geometry.py',None,None),
      ('check_localizer12_safety_units.py',"O=R/'build/localizer12_safety'/('before_units' if a.before else 'final_units')",f'O=Path({str(O/"controller_units")!r})'),
      ('check_pdm_constraints.py',"OUT=ROOT/'build/pdm_constraints_check'",f'OUT=Path({str(O/"constraints")!r})')]:
        src=R/'scripts'/script
        code=src.read_text()
        if old:
            assert old in code
            code=code.replace(old,new)
        log=io.StringIO(); prev=sys.argv; sys.argv=[str(src)]
        status='PASS'; err=None
        try:
            with contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):
                exec(compile(code,str(src),'exec'),{'__file__':str(src),'__name__':'__main__'})
        except BaseException as e:
            status='FAIL';err=repr(e)
        finally:sys.argv=prev
        (O/(script+'.log')).write_text(log.getvalue()+(err or ''),encoding='utf-8')
        checks.append({'script':script,'status':status,'error':err,'scope':'geometry gate / controller stubs / XDC generation only'})
write('checks.json',checks)
# Confirm the protected baseline has not changed while auditing.
changed=[x['path'] for x in files if not (R/x['path']).is_file() or digest(R/x['path'])!=x['sha256']]
write('baseline_preservation.json',{'protected_files':len(files),'changed':changed,'status':'PASS' if not changed else 'FAIL','git_status_after':git('status','--short')})
write('audit_manifest.json',{'head':state['head'],'stage':'M0','engineering_status':'PARTIAL','new_rtl_changes':False,
    'files':{q.relative_to(O).as_posix():digest(q) for q in O.rglob('*') if q.is_file()}})
print(json.dumps({'output':str(O),'protected':len(files),'baseline_changed':changed,'comparisons':comparisons,'checks':checks},indent=2))
