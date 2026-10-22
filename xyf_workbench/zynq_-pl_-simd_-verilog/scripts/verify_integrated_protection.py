from pathlib import Path
import hashlib,json
R=Path(__file__).resolve().parents[1];P=R/'build/zynq12_integrated_plan';old=json.loads((P/'audit/m0_20261015/protected_artifacts.json').read_text())
def sha(p):
 h=hashlib.sha256()
 with p.open('rb')as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
artifacts=[x for x in old if Path(x['path']).suffix.lower() in ['.bit','.xsa','.elf','.log'] or 'manifest' in Path(x['path']).name.lower()]
changed=[x['path'] for x in artifacts if not(R/x['path']).is_file()or sha(R/x['path'])!=x['sha256']]
baseline={x['path']:x['sha256'] for x in old}
must_keep=['configs/production_array.json','rtl/core/rv32_core.v','rtl/soc/rv32_dtcm.v','rtl/soc/rv32_itcm.v','rtl/memory/rv32_lsu.v',
 'rtl/vec/rv32_vec_unit.v','rtl/acoustic/rv32_fft_bfly.v','rtl/acoustic/rv32_acoustic_ext.v','rtl/srp/rv32_srp_scan.v',
 'rtl/array/rv32_pdm_array_rx.v','rtl/array/rv32_chan_align.v','rtl/rom/pdm_hann_q14.hex','constrs/ps_pl_wrapper.xdc']
same={p:sha(R/p)==baseline[p] for p in must_keep}
config=json.loads((R/'configs/production_array.json').read_text())
assert config['mic_xyz']is None and config['channel_to_mic']is None and not config['physical_mapping_confirmed']
data={'status':'PASS' if not changed and all(same.values()) else 'FAIL','protected_artifact_count':len(artifacts),
 'changed_old_artifacts':changed,'unchanged_baseline_code_and_config':same,'production_geometry_enabled':False,
 'default_log_restore':json.loads((P/'default_log_restoration.json').read_text(encoding='utf-8-sig'))}
out=P/'protected_verification.json';assert not out.exists();out.write_text(json.dumps(data,indent=2));print(json.dumps(data,indent=2));assert data['status']=='PASS'
