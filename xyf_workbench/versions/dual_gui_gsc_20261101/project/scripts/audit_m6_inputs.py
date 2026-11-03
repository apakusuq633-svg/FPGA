"""Read-only audit plus new evidence outputs; does not connect to hardware."""
from pathlib import Path
import csv,hashlib,json,re,subprocess,sys,contextlib,io
R=Path(__file__).resolve().parents[1];O=R/'build/m6_20261016'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def evidence(path,pattern):
    lines=(R/path).read_text(encoding='utf-8').splitlines()
    matches=[{'file':path,'line':i,'text':t.strip()} for i,t in enumerate(lines,1) if re.search(pattern,t)]
    assert matches,(path,pattern)
    return matches
config=json.loads((R/'configs/production_array.json').read_text())
assert config['channels']==12 and config['data_lines']==6 and config['mics_per_line']==2
assert config['mic_xyz'] is None and config['channel_to_mic'] is None and not config['physical_mapping_confirmed']
mapping=[]
for ch in range(12):
    k=ch//2;pin=config['din_pins'][k]
    evidence_pin=evidence('constrs/ps_pl_wrapper.xdc',r'PACKAGE_PIN '+pin+r'.*pdm_din_i\['+str(k)+r'\]')
    mapping.append({'rtl_channel':ch,'configured_data_line':k,'configured_package_pin':pin,
      'documented_J3_pin':[31,32,33,34,35,26][k],'expected_LR':'GND' if ch%2==0 else 'VDD',
      'physical_mic_id':None,'physical_position_m':None,'hardware_status':'UNVERIFIED_HARDWARE',
      'pin_evidence':evidence_pin})
report={'scope':'CONFIGURATION_ONLY','target_part':'xc7z020clg400-1','physical_part':'UNVERIFIED_HARDWARE',
 'top':'ps_pl_wrapper','internal_top':'rv32_ps_top','pl_clock_hz':40000000,
 'pdm_bit_rate_per_mic':2500000,'decimation':64,'pcm_sample_rate_hz':39062.5,'mapping':mapping,
 'evidence':sum([evidence('scripts/create_zynq_project.tcl',r'set part|fclk_mhz|write_pdm_constraints'),
   evidence('rtl/soc/rv32_ps_top.v',r'parameter DAS_ACTIVE|parameter PDM_MICS|input.*pdm_din_i'),
   evidence('rtl/array/rv32_pdm_array_rx.v',r'CH_A =|CH_B =|HOLD_TICK|CONSUME_TICK'),
   evidence('rtl/soc/rv32_soc.v',r'\.sample_seq_i\(pdm_frame_cnt\)|\.sample_id_i\(pdm_frame_cnt\)'),
   evidence('constrs/ps_pl_wrapper.xdc',r'set_false_path.*pdm')],[])}
(O/'input_audit.json').write_text(json.dumps(report,indent=2))
with (O/'channel_mapping.csv').open('w',newline='') as f:
    names=[k for k in mapping[0] if k!='pin_evidence'];writer=csv.DictWriter(f,fieldnames=names,extrasaction='ignore');writer.writeheader();writer.writerows(mapping)
# Redirect the existing pure-XDC profile test into an unused M6 evidence directory.
script=R/'scripts/check_pdm_constraints.py'
code=script.read_text().replace("OUT=ROOT/'build/pdm_constraints_check'","OUT=ROOT/'build/m6_20261016/constraints'")
log=io.StringIO()
with contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):exec(compile(code,str(script),'exec'),{'__name__':'__main__','__file__':str(script)})
(O/'constraints_check.log').write_text(log.getvalue())
source_manifest={str(p.relative_to(R)):sha(p) for folder in ['rtl','constrs','configs'] for p in (R/folder).rglob('*') if p.is_file()}
(O/'implementation_sources.json').write_text(json.dumps(source_manifest,indent=2))
q=subprocess.run(['git','diff','--no-ext-diff','--binary'],cwd=R,capture_output=True,text=True);assert q.returncode==0
(O/'tracked_diff.txt').write_text(q.stdout)
print('M6_INPUT_AUDIT_PASS hardware=UNVERIFIED_HARDWARE')
