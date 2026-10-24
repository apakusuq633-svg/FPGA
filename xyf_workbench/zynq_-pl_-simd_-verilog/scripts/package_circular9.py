"""Bundle matched 9-mic build artifacts without claiming physical acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import zipfile

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def words(path):return [int(w,16) for w in path.read_text().split()]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--project',type=Path,default=ROOT/'build/c9ov50')
    parser.add_argument('--flow-log',type=Path,default=ROOT/'build/c9ov50_resume2_console.log')
    parser.add_argument('--bsp-workspace',type=Path,required=True)
    args=parser.parse_args()
    log=args.flow_log.read_text(encoding='utf-8',errors='replace')
    if not re.search(r'^FLOW_PASS:',log,re.M) or re.search(r'^FLOW_FAIL:',log,re.M):raise RuntimeError('Need completed implementation, including timing checks')
    built=ROOT/'build/circular9_gsc';fw=ROOT/'build/circular9/fw'
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
    if manifest['simulation_only'] or manifest['localizer_abi']!='P9D2' or manifest['hop_samples']!=512:
        raise RuntimeError('Not the production 50% overlap profile')
    for name,digest in manifest['source_sha256'].items():
        if sha(ROOT/name)!=digest:raise RuntimeError('Source changed since firmware generation: '+name)
    tests=json.loads((ROOT/'build/circular9_checks/results.json').read_text())
    if tests['firmware_sha256']!=sha(fw/'itcm.hex'):raise RuntimeError('Firmware differs from tested image')
    if tests['latency']['first_aligned_pcm_to_even_rv32_publication_ms_max']>=10:raise RuntimeError('Digital latency missed')
    report=(built/'timing_zynq.rpt').read_text(errors='replace')
    setup=re.search(r'Worst Slack\s+([-\d.]+)ns',report)
    if not setup or float(setup[1])<0:raise RuntimeError('Missing or failing timing report')
    platform_xsa=list(args.bsp_workspace.glob('circular9/hw/*.xsa'))
    if len(platform_xsa)!=1 or sha(platform_xsa[0])!=sha(xsa):raise RuntimeError('BSP was not generated from this XSA')
    out=ROOT/'build/circular9_release';out.mkdir(exist_ok=True)
    sources={
        'pl.bit':bit,'hardware.xsa':xsa,'ps_ui.elf':elf,'rv32.elf':fw/'fw_circular9.elf',
        'rv32_itcm.hex':fw/'itcm.hex','rv32_dtcm.hex':fw/'dtcm.hex',
        'srp_lut.hex':ROOT/'build/circular9/srp_lut.hex','steer_lut.hex':ROOT/'build/circular9/steer_lut.hex',
        'array.json':ROOT/'configs/circular9_array.json','bearing.json':ROOT/'configs/bearing_6004_2zr.json',
        'timing.rpt':built/'timing_zynq.rpt','utilization.rpt':built/'util_zynq.rpt','io.rpt':built/'io_zynq.rpt',
        'digital_checks.json':ROOT/'build/circular9_checks/results.json','pdm_to_gsc_checks.json':ROOT/'build/circular9_e2e/results.json',
        'latency_contract.md':ROOT/'docs/circular9_latency_contract_20261023.md'}
    files={}
    for name,path in sources.items():
        shutil.copyfile(path,out/name);files[name]={'sha256':sha(path),'bytes':path.stat().st_size}
    package={'status':'BUILD_AND_DIGITAL_VERIFIED_BOARD_UNVERIFIED','board_tested':False,
        'physical_geometry_confirmed':manifest['geometry_confirmed'],'ps_runtime_latency_measured':False,
        'classifier_validated':False,'abi':'P9D2','sample_rate_hz':156250,'window_samples':1024,'hop_samples':512,
        'latency':tests['latency'],'files':files,'source_snapshot_sha256':manifest['source_sha256'],
        'bsp_workspace':str(args.bsp_workspace),'flow_log_sha256':sha(args.flow_log)}
    (out/'manifest.json').write_text(json.dumps(package,indent=2)+'\n',encoding='utf-8')
    print('CIRCULAR9_PACKAGE_PASS board=UNVERIFIED ps_runtime=UNMEASURED '+str(out))

if __name__=='__main__':main()
