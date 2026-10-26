"""Bundle matched 9-mic build artifacts without claiming physical acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import zipfile
from circular9_model_release import inspect_model_release
from circular9_routed_evidence import snapshot as routed_snapshot

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def words(path):return [int(w,16) for w in path.read_text().split()]
def verify_sources(document):
    for name,digest in document.get('source_sha256',document.get('sources',{})).items():
        if sha(ROOT/name)!=digest:raise RuntimeError('Evidence is stale: '+name)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--project',type=Path,default=ROOT/'build/c9opt')
    parser.add_argument('--hardware-output',type=Path,default=ROOT/'build/circular9_optimized_hw')
    parser.add_argument('--flow-log',type=Path,default=ROOT/'build/c9opt_console.log')
    parser.add_argument('--bsp-workspace',type=Path,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'build/circular9_direction_release')
    args=parser.parse_args()
    raw_log=args.flow_log.read_bytes()
    log=raw_log.decode('utf-16' if raw_log[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8',errors='replace')
    if not re.search(r'^FLOW_PASS:',log,re.M) or re.search(r'^FLOW_FAIL:',log,re.M):raise RuntimeError('Need completed implementation, including timing checks')
    built=args.hardware_output;fw=ROOT/'build/circular9/fw'
    bit=args.project/'rv32_zynq.runs/impl_1/ps_pl_wrapper.bit'
    xsa=built/'das_fir.xsa';elf=ROOT/'build/ui_pipeline_circular9/ui.elf'
    with zipfile.ZipFile(xsa) as archive:
        embedded=[n for n in archive.namelist() if n.endswith('.bit')]
        if len(embedded)!=1 or hashlib.sha256(archive.read(embedded[0])).hexdigest()!=sha(bit):
            raise RuntimeError('XSA and routed bitstream differ')
    # Prove that the PS loader embeds the tested RV32 bytes and geometry tables.
    image=elf.read_bytes()
    for source in [fw/'itcm.hex',ROOT/'build/circular9/srp_lut.hex',ROOT/'build/circular9/steer_lut.hex']:
        data=words(source)
        if struct.pack('<'+'I'*len(data),*data) not in image:raise RuntimeError('PS image mismatch: '+str(source))
    manifest=json.loads((ROOT/'build/circular9/build_manifest.json').read_text())
    config=Path(manifest.get('config_path',ROOT/'configs/circular9_array.json'))
    if manifest.get('config_sha256')!=sha(config):raise RuntimeError('Array configuration changed since firmware generation')
    if manifest['simulation_only'] or manifest['localizer_abi']!='P9D2' or manifest['hop_samples']!=512:
        raise RuntimeError('Not the production 50% overlap profile')
    for name,digest in manifest['source_sha256'].items():
        if sha(ROOT/name)!=digest:raise RuntimeError('Source changed since firmware generation: '+name)
    if manifest.get('scan_model')!='far_field_direction':raise RuntimeError('Not the direction-only profile')
    # This implementation adds RTL. Bind a fresh completed run to its source
    # snapshot; an old bitstream's source manifest cannot certify this build.
    routed=json.loads((built/'routed_source_proof.json').read_text())
    if (routed.get('status')!='ROUTED_SOURCE_AND_XSA_MATCHED' or
        routed.get('bit_sha256')!=sha(bit) or routed.get('xsa_sha256')!=sha(xsa) or
        routed.get('source_sha256')!=routed_snapshot()):
        raise RuntimeError('Fresh routed implementation/source/XSA evidence does not match')
    verify_sources(routed)
    rtl_sources={p.relative_to(ROOT).as_posix():sha(p) for p in sorted((ROOT/'rtl').rglob('*.v'))}
    ps_build=json.loads((ROOT/'build/ui_pipeline_circular9/build_manifest.json').read_text(encoding='utf-8-sig'))
    if ps_build['elf_sha256']!=sha(elf):raise RuntimeError('PS ELF differs from its build manifest')
    verify_sources(ps_build)
    expected_bsp=args.bsp_workspace/'circular9/export/circular9/sw/circular9/standalone_domain'
    if Path(ps_build['bsp_dir']).resolve()!=expected_bsp.resolve():raise RuntimeError('PS compiled against a different BSP')
    if ps_build.get('diagnostic_model_header') and sha(Path(ps_build['diagnostic_model_header']))!=ps_build['diagnostic_model_sha256']:
        raise RuntimeError('Diagnostic model changed since PS build')
    model_release=inspect_model_release(ps_build)
    tests=json.loads((ROOT/'build/circular9_checks/results.json').read_text())
    if tests['firmware_sha256']!=sha(fw/'itcm.hex'):raise RuntimeError('Firmware differs from tested image')
    if tests['latency']['first_aligned_pcm_to_even_rv32_publication_ms_max']>=10:raise RuntimeError('Digital latency missed')
    verify_sources(tests)
    extra_checks={}
    for name,directory in [('direction','circular9_direction_checks'),('separation','circular9_candidates_checks'),
                           ('diagnosis','circular9_diagnosis_checks'),('pipeline','circular9_pipeline_checks'),('pdm_gsc','circular9_e2e'),
                           ('proposals','circular9_proposals_checks'),('tracking','circular9_tracking_checks'),
                           ('envelope','circular9_envelope_checks'),('gsc_regression','gsc9_checks'),
                           ('loader','circular9_loader_checks'),('calibration','circular9_calibration_checks'),
                           ('preflight','circular9_preflight_checks'),('receiver','circular9_receive_checks'),
                           ('model_release','circular9_model_release_checks'),
                           ('gsc_hotpath','gsc9_hotpath_checks'),('control_rtl','circular9_control_checks'),
                           ('ps_control','circular9_ps_control_checks'),('schedule','circular9_schedule_checks'),
                           ('aux','circular9_aux_checks')]:
        check=json.loads((ROOT/'build'/directory/'results.json').read_text())
        if not (check.get('passed') or check.get('status') in ('PASS_DIGITAL','PASS_NATIVE')):raise RuntimeError(name+' did not pass')
        verify_sources(check);extra_checks[name]=check
    if extra_checks['pdm_gsc']['firmware_sha256']!=sha(fw/'itcm.hex'):raise RuntimeError('PDM/GSC evidence has different firmware')
    for name,digest in extra_checks['pdm_gsc']['lut_sha256'].items():
        if sha(ROOT/'build/circular9'/name)!=digest:raise RuntimeError('PDM fixture has different LUT: '+name)
    report=(built/'timing_zynq.rpt').read_text(errors='replace')
    setup=re.search(r'Worst Slack\s+([-\d.]+)ns',report)
    if not setup or float(setup[1])<0:raise RuntimeError('Missing or failing timing report')
    platform_xsa=list(args.bsp_workspace.glob('circular9/hw/*.xsa'))
    if len(platform_xsa)!=1 or sha(platform_xsa[0])!=sha(xsa):raise RuntimeError('BSP was not generated from this XSA')
    out=args.output;out.mkdir(exist_ok=True)
    sources={
        'pl.bit':bit,'hardware.xsa':xsa,'ps_ui.elf':elf,'rv32.elf':fw/'fw_circular9.elf',
        'ps7_init.tcl':args.bsp_workspace/'circular9/hw/ps7_init.tcl',
        'rv32_itcm.hex':fw/'itcm.hex','rv32_dtcm.hex':fw/'dtcm.hex',
        'srp_lut.hex':ROOT/'build/circular9/srp_lut.hex','steer_lut.hex':ROOT/'build/circular9/steer_lut.hex',
        'array.json':config,'bearing.json':ROOT/'configs/bearing_6004_2zr.json',
        'timing.rpt':built/'timing_zynq.rpt','utilization.rpt':built/'util_zynq.rpt','io.rpt':built/'io_zynq.rpt',
        'digital_checks.json':ROOT/'build/circular9_checks/results.json','pdm_to_gsc_checks.json':ROOT/'build/circular9_e2e/results.json',
        'latency_contract.md':ROOT/'docs/circular9_latency_contract_20261023.md',
        'original_plan.md':ROOT/'docs/circular9_fault_localization_plan_20261022.md',
        'board_bringup.md':ROOT/'docs/circular9_board_bringup_20261024.md',
        'direction_scan.md':ROOT/'docs/circular9_direction_scan_20261025.md',
        'diagnosis_workflow.md':ROOT/'docs/circular9_diagnosis_data_workflow_20261025.md',
        'direction_separation.md':ROOT/'docs/circular9_direction_separation_20261025.md',
        'optimization.md':ROOT/'docs/circular9_optimization_20261025.md',
        'optimization_completion.md':ROOT/'docs/circular9_optimization_completion_20261025.md',
        'gsc_hotpath_guard.md':ROOT/'docs/gsc9_hotpath_guard_20261025.md',
        'spectral_covariance.md':ROOT/'docs/circular9_spectral_covariance_20261025.md',
        'routed_source_proof.json':built/'routed_source_proof.json',
        'circular9_dataset.py':ROOT/'pc/circular9_dataset.py',
        'circular9_receive.py':ROOT/'pc/circular9_receive.py',
        'circular9_capture.py':ROOT/'pc/circular9_capture.py',
        'circular9_preflight.py':ROOT/'pc/circular9_preflight.py',
        'circular9_calibration.py':ROOT/'scripts/circular9_calibration.py',
        'build_circular9.py':ROOT/'scripts/build_circular9.py',
        'preflight_workflow.md':ROOT/'docs/circular9_preflight_20261025.md',
        'calibration_workflow.md':ROOT/'docs/circular9_calibration_input_20261025.md',
        'readiness.md':ROOT/'docs/circular9_readiness_20261025.md',
        'packet_capture.md':ROOT/'docs/circular9_packet_capture_20261025.md',
        'ps_build.json':ROOT/'build/ui_pipeline_circular9/build_manifest.json',
        'direction_checks.json':ROOT/'build/circular9_direction_checks/results.json',
        'separation_checks.json':ROOT/'build/circular9_candidates_checks/results.json',
        'diagnosis_checks.json':ROOT/'build/circular9_diagnosis_checks/results.json',
        'pipeline_checks.json':ROOT/'build/circular9_pipeline_checks/results.json',
        'proposals_checks.json':ROOT/'build/circular9_proposals_checks/results.json',
        'tracking_checks.json':ROOT/'build/circular9_tracking_checks/results.json',
        'envelope_checks.json':ROOT/'build/circular9_envelope_checks/results.json',
        'loader_checks.json':ROOT/'build/circular9_loader_checks/results.json',
        'calibration_checks.json':ROOT/'build/circular9_calibration_checks/results.json',
        'preflight_checks.json':ROOT/'build/circular9_preflight_checks/results.json',
        'receiver_checks.json':ROOT/'build/circular9_receive_checks/results.json',
        'model_release_checks.json':ROOT/'build/circular9_model_release_checks/results.json',
        'gsc_regression.json':ROOT/'build/gsc9_checks/results.json',
        'gsc_hotpath_checks.json':ROOT/'build/gsc9_hotpath_checks/results.json',
        'control_rtl_checks.json':ROOT/'build/circular9_control_checks/results.json',
        'ps_control_checks.json':ROOT/'build/circular9_ps_control_checks/results.json',
        'aux_checks.json':ROOT/'build/circular9_aux_checks/results.json',
        'schedule_checks.json':ROOT/'build/circular9_schedule_checks/results.json'}
    # Keep original documentation basenames so relative links in the copied
    # handbooks remain usable beside the stable release aliases.
    for source in tuple(sources.values()):
        if source.suffix=='.md':sources.setdefault(source.name,source)
    sources.update(model_release['files'])
    for name in ('diagnostic_model.h','diagnostic_model.json'):
        if name not in sources and (out/name).is_file():(out/name).unlink()
    files={}
    for name,path in sources.items():
        shutil.copyfile(path,out/name);files[name]={'sha256':sha(path),'bytes':path.stat().st_size}
    package={'status':'BUILD_AND_DIGITAL_VERIFIED_BOARD_UNVERIFIED','board_tested':False,
        'physical_geometry_confirmed':manifest['geometry_confirmed'],'ps_runtime_latency_measured':False,
        'classifier_validated':model_release['classifier_validated'],
        'model_version':model_release['model_version'],'model_kind':model_release['model_kind'],
        'model_review_id':model_release['review_id'],'model_release_status':model_release['status'],
        'model_validation_source_sha256':model_release['evidence_source_sha256'],
        'scan_model':'far_field_direction','separation':'PS_CPU1_MEASURED_RESIDUAL_COVARIANCE_SECTOR_MAX3',
        'qualification_scope':'guarded_capture_and_calibration_tests; physical fault-direction acceptance unverified',
        'calibration_status':manifest['calibration_status'],'calibration_version':manifest['calibration_version'],
        'array_config_sha256':sha(config),
        'feature_contract':'C9F2','separation_contract':'C9S3','candidate_map_period_ms':20,
        'diagnostic_window_ms':1024,'diagnostic_hop_ms':512,'diagnostic_deadline_ms':3000,
        'diagnostic_result_age_limit_ms':3000,
        'raw_history_frames':1048576,'raw_history_seconds':1048576/156250,
        'fine_delay_contract':'atomic calibrated Q4 delays, shared PL DAS and PS GSC',
        'tachometer':'filtered period measurement, explicit PPR, timeout, generation barriers',
        'diagnostic_model_header':ps_build.get('diagnostic_model_header',''),
        'abi':'P9D2','sample_rate_hz':156250,'window_samples':1024,'hop_samples':512,
        'latency':tests['latency'],'files':files,'source_snapshot_sha256':manifest['source_sha256'],
        'bsp_workspace':str(args.bsp_workspace),'flow_log_sha256':sha(args.flow_log),
        'routed_source_sha256':routed['source_sha256'],
        'routed_rtl_sha256':rtl_sources,'ps_source_sha256':ps_build['source_sha256']}
    (out/'manifest.json').write_text(json.dumps(package,indent=2)+'\n',encoding='utf-8')
    print('CIRCULAR9_PACKAGE_PASS board=UNVERIFIED ps_runtime=UNMEASURED '+str(out))

if __name__=='__main__':main()
