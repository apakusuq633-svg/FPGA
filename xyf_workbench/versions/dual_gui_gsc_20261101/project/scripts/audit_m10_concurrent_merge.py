"""Archive SHA-proven prior tool versions; retain all concurrent edits in place."""
from pathlib import Path
import difflib,hashlib,itertools,json,subprocess
R=Path(__file__).resolve().parents[1];O=R/'build/m10_20261016';B=O/'before'
before=json.loads((O/'before_sources.json').read_text(encoding='utf-8-sig'))
m9=json.loads((R/'build/m9_merge_20261016/release_manifest.json').read_text())
expected=dict(before);expected.update({row['path']:row['sha256'] for row in m9['files'] if row['path'].startswith('docs/')})
sha=lambda b:hashlib.sha256(b).hexdigest()
def archive(name,data):
 if sha(data)!=expected[name]:
  # Windows writers can normalize line endings. Accept a representation only
  # when its complete bytes match the previously recorded SHA256 exactly.
  text=data.decode('utf-8-sig').replace('\r\n','\n')
  options=[text.encode(),text.replace('\n','\r\n').encode()]
  options += [b'\xef\xbb\xbf'+b for b in options]
  for option in options:
   if sha(option)==expected[name]:data=option;break
 assert sha(data)==expected[name],('Cannot reconstruct exact historical input',name,sha(data),expected[name])
 f=B/('external_'+Path(name).name)
 if f.exists():assert f.read_bytes()==data
 else:f.write_bytes(data)
 return str(f.relative_to(R))
files={}
name='scripts/check_localizer12_safety.py'
data=subprocess.check_output(['git','show','HEAD:zynq_-pl_-simd_-verilog/'+name],cwd=R)
files[name]=archive(name,data)
current=(R/name).read_text()
parser_line="p.add_argument('--rtl-overlay',type=Path,help='Isolated SRP/localizer RAM mapping experiment')\n"
overlay_files='''if a.rtl_overlay:
 overlay=a.rtl_overlay.resolve()
 for f in overlay.glob('*.v'):
  assert f.name in ['rv32_srp_scan.v','rv32_overlap_localizer.v'],f
  files=[f if old.name==f.name else old for old in files]
  sources[str(f.relative_to(R))]=hashlib.sha256(f.read_bytes()).hexdigest()
'''
overlay_wrapper='''if a.rtl_overlay and 'g_banked' in (overlay/'rv32_srp_scan.v').read_text():
 text=wrapper.read_text()
 prefix='dut.u_srp.u_scan.'
 old=prefix+'lut_mem[debug_addr]'
 assert text.count(old)==1
 expr='(debug_addr<32768?'+prefix+'g_banked.lut_lo[debug_addr[14:0]]:debug_addr<65536?'+prefix+'g_banked.lut_mid[debug_addr[14:0]]:'+prefix+'g_banked.lut_tail[debug_addr[10:0]])'
 wrapper.write_text(text.replace(old,expr))
'''
for block in (parser_line,overlay_files,overlay_wrapper):
 assert current.count(block)==1;current=current.replace(block,'')
assert sha(current.encode())==before[name],'Default checker body changed beyond optional overlay'
name='scripts/create_zynq_project.tcl';current=(R/name).read_text()
begin=current.index('# Opt-in isolated RAM experiment;')
end=current.index('# ---- 建工程 ----',begin)
files[name]=archive(name,(current[:begin]+current[end:]).encode())
assert b'PDM_RAM_EXPERIMENT_OVERLAY' not in (R/'build/zynq12_integrated_plan/m10_impl_20261016/implementation.log').read_bytes()
name='sw/ps_pdm.c'
head=subprocess.check_output(['git','show','HEAD:zynq_-pl_-simd_-verilog/'+name],cwd=R).decode()
needle='    /* -- 2. sample rate, measured rather than assumed ----------------------------------- */\n'
startup='''    /* The default receiver suppresses PCM for 50ms plus CIC settling. */
    for (i = 0; i < POLL_LIMIT; i++) {
        if (Xil_In32(RV32_BASE + R_FRAME) != started) break;
    }
    if (i == POLL_LIMIT) {
        xil_printf("[FAIL] PDM startup produced no PCM group\\r\\n");
        return 1;
    }
'''
assert head.count(needle)==1
# The parallel task also corrected older diagnostics. Recover the exact prior
# version by selecting known line-edit blocks; never write to the live source.
old_lines=head.splitlines(True);new_lines=(R/name).read_text().splitlines(True)
ops=difflib.SequenceMatcher(None,old_lines,new_lines,autojunk=False).get_opcodes()
changes=[op for op in ops if op[0]!='equal'];assert len(changes)<=14
recovered=None
for choices in itertools.product((False,True),repeat=len(changes)):
 parts=[];index=0
 for tag,i,j,k,l in ops:
  use_new=False if tag=='equal' else choices[index]
  if tag!='equal':index+=1
  parts.extend(new_lines[k:l] if use_new else old_lines[i:j])
 text=''.join(parts)
 for candidate in (text.encode(),text.replace('\n','\r\n').encode()):
  if sha(candidate)==before[name]:recovered=candidate;break
 if recovered is not None:break
assert recovered is not None,'Historical PS diagnostic source is not among known edit blocks'
files[name]=archive(name,recovered)
name='scripts/check_ps_pdm_startup.py';current=(R/name).read_text()
current=current.replace(";p.add_argument('--protocol',action='store_true')",'')
current=current.replace(";p.add_argument('--expect-defects',action='store_true')",'')
current=current.replace(";p.add_argument('--source',type=Path,help='Explicit archived C source for reproducible A/B protocol checks')",'')
begin=current.index('if a.protocol:\n');end=current.index("body=r'''",begin)
files[name]=archive(name,(current[:begin]+current[end:]).encode())
external=['sw/ps_pdm.c','scripts/create_zynq_project.tcl','scripts/check_localizer12_safety.py',
 'scripts/check_ps_pdm_startup.py','scripts/pdm_external_window.tcl','scripts/check_pdm_external_sta.tcl']
supporting=[]
for name in ('docs/issues/README.md','docs/board_io.md','docs/pdm_array_spec.md','docs/measurements.md'):
 if sha((R/name).read_bytes())==expected[name]:continue
 prior=B/('external_'+Path(name).name)
 available=prior.is_file() and sha(prior.read_bytes())==expected[name]
 if available:files[name]=str(prior.relative_to(R))
 # Supporting prose is allowed to evolve under the authorized merge. Preserve
 # its old manifest hash and a current snapshot; never waive a test/bit/source.
 snapshot=O/'concurrent_document_snapshot'/name;snapshot.parent.mkdir(parents=True,exist_ok=True)
 snapshot.write_bytes((R/name).read_bytes())
 supporting.append(dict(path=name,before_sha256=expected[name],current_sha256=sha((R/name).read_bytes()),
 historical_text_archived=available,current_snapshot=str(snapshot.relative_to(R))))
report=dict(status='DEFAULT_PATH_EQUIVALENCE_PROVED',historical_copies=files,
 audit_script_sha256=sha(Path(__file__).read_bytes()),
 supporting_doc_updates=supporting,
 default_overlay_enabled=False,concurrent_changes=[dict(path=name,before_sha256=before[name],
 current_sha256=sha((R/name).read_bytes())) for name in external],
 note='PS capture diagnostic strengthened separately; external timing tools are not the frozen model used by this M10 audit.')
config=R/'configs/pdm_external_assumptions.json';values=json.loads(config.read_text())
assert values['status']=='ASSUMED_NOT_MEASURED' and values['hardware']=='UNVERIFIED_HARDWARE'
for field,value in dict(schema=1,part='xc7z020clg400-1',system_period_ns=25.,sample_after_drive_ns=125.,
 mic_tdv_max_ns=100.,mic_thz_min_ns=5.,pcb_clock_min_ns=0.,pcb_clock_max_ns=3.,
 pcb_data_min_ns=0.,pcb_data_max_ns=3.,relative_uncertainty_ns=2.).items():assert values[field]==value
report['additional_configs']=[dict(path=str(config.relative_to(R)),sha256=sha(config.read_bytes()),
 synthesized_input=False,assumptions_match_frozen_analysis=True)]
(O/'concurrent_merge.json').write_text(json.dumps(report,indent=2))
print('M10_CONCURRENT_DEFAULT_PATH_AUDIT_PASS')
