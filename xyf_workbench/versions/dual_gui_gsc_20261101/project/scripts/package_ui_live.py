"""Package matching PL artifacts and the FIFO GUI; never claim board acceptance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def digest(data):
    return hashlib.sha256(data).hexdigest()

def read(path):
    raw=path.read_bytes()
    return raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8',errors='replace')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--debug4",action="store_true")
    parser.add_argument("--legacy8",action="store_true")
    args=parser.parse_args();debug4=args.debug4
    if not debug4 and not args.legacy8:
        from package_planar8 import main as package8
        package8()
        return
    names = [
        'build/ui_pipeline_live/ui.elf', 'build/acoustic_arm/live_das.elf',
        'build/das_fir.xsa', 'build/das_fir_routed.dcp',
        'build/das_fir_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit',
        'build/das_fir_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl',
        'build/timing_zynq.rpt', 'build/util_zynq.rpt', 'build/das_fir_zynq_console.log',
    ]
    if debug4:
        names=[name.replace("build/ui_pipeline_live/", "build/ui_pipeline_live4/").replace("build/acoustic_arm/live_das.elf", "build/das4/fw/fw_debug4.elf").replace("build/das_fir_zynq/", "build/das4_zynq/").replace("build/das_fir_zynq_console.log", "build/das4_console.log") for name in names]
        names=[name.replace("build/das_fir.xsa", "build/das4/das_fir.xsa").replace("build/das_fir_routed.dcp", "build/das4/das_fir_routed.dcp").replace("build/timing_zynq.rpt", "build/das4/timing_zynq.rpt").replace("build/util_zynq.rpt", "build/das4/util_zynq.rpt") for name in names]
        flows=[ROOT/'build'/p for p in ('das4_console.log','das4_pins_console.log','das4_quality_console.log','das4_release_console.log')]
        flows=[p for p in flows if p.is_file() and 'FLOW_PASS:' in read(p)]
        if flows:names[-1]=str(max(flows,key=lambda p:p.stat().st_mtime_ns).relative_to(ROOT)).replace('\\','/')
    missing = [name for name in names if not (ROOT/name).is_file()]
    if missing:
        raise SystemExit('UI_LIVE_PACKAGE_FAIL: missing ' + ', '.join(missing))
    flow = read(ROOT/names[-1])
    if 'FLOW_PASS:' not in flow:
        raise SystemExit('UI_LIVE_PACKAGE_FAIL: implementation did not pass')
    report = (ROOT/names[6]).read_text()
    timing = re.search(r'^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s', report, re.M)
    if not timing or float(timing[1]) < 0 or float(timing[5]) < 0 or int(timing[3]) or int(timing[7]):
        raise SystemExit('UI_LIVE_PACKAGE_FAIL: setup/hold timing failed')
    bit = (ROOT/names[4]).read_bytes()
    with zipfile.ZipFile(ROOT/names[2]) as archive:
        bits = [name for name in archive.namelist() if name.endswith('.bit')]
        if len(bits) != 1 or digest(archive.read(bits[0])) != digest(bit):
            raise SystemExit('UI_LIVE_PACKAGE_FAIL: bit/XSA mismatch')
    image_name='acoustic_debug4_image.h' if debug4 else 'acoustic_live_image.h'
    image = (ROOT/'sw'/image_name).read_text()
    for memory in ('itcm','dtcm'):
        expected = re.search('ACOUSTIC_'+memory.upper()+'_SHA256 "([0-9a-f]{64})"', image)
        if not expected or digest((ROOT/(f'build/das4/fw/{memory}.hex' if debug4 else f'sw/fw/fw_live_{memory}.hex')).read_bytes()) != expected[1]:
            raise SystemExit('UI_LIVE_PACKAGE_FAIL: firmware hash mismatch')
    ui_sources = ['ps_ui.c','ps_ui_page.h','ps_das_fifo.h','ps_pl_live.h','acoustic_live_image.h',
                  'ps_das_audio.h','ps_das_mmio.h','ps_das_report.h','das_audio_contract.h',
                  'ps_diag.h','ps_features.h','ps_classifier.h','ps_output.h','ps_ipc.h','ps_das_plots.h','ps_mic_levels.h','ps_http_tx.h']
    ui_sources=[image_name if name=='acoustic_live_image.h' else name for name in ui_sources]
    elf_time = (ROOT/names[0]).stat().st_mtime_ns
    if any((ROOT/'sw'/name).stat().st_mtime_ns > elf_time for name in ui_sources):
        raise SystemExit('UI_LIVE_PACKAGE_FAIL: UI source newer than ELF')
    checkpoint_time = (ROOT/names[3]).stat().st_mtime_ns
    implementation_sources = list((ROOT/'rtl').rglob('*.v')) + [ROOT/'constrs/ps_pl_wrapper.xdc', ROOT/'scripts/create_zynq_project.tcl']
    if debug4:
        implementation_sources.append(ROOT/'scripts/configure_debug4_pins.tcl')
        io_report=(ROOT/'build/das4/io_zynq.rpt').read_text()
        for channel,pin in enumerate(('T14','Y17','T15','W16')):
            if not re.search(r'\|\s*'+pin+r'\s*\|\s*pdm_din_i\['+str(channel)+r'\]\s*\|',io_report):
                raise SystemExit('UI_LIVE_PACKAGE_FAIL: debug4 pin mapping mismatch')
    if any(path.stat().st_mtime_ns > checkpoint_time for path in implementation_sources):
        raise SystemExit('UI_LIVE_PACKAGE_FAIL: implementation source or pin constraints newer than checkpoint')
    if any(path.stat().st_mtime_ns > checkpoint_time for path in (ROOT/'rtl').rglob('*.v')):
        raise SystemExit('UI_LIVE_PACKAGE_FAIL: RTL newer than implementation')
    if debug4:
        bench=ROOT/'tb/tb_live4_quality.v'
        log=ROOT/'build/das4/xsim_quality/simulation.log'
        kernel=log.parent/'xsim.dir/live16_soc/xsimk.exe'
        if 'LIVE4_QUALITY_SOC_PASS' not in read(log):raise SystemExit('UI_LIVE_PACKAGE_FAIL: four-mic quality regression did not pass')
        dependencies=list((ROOT/'rtl').rglob('*.v'))+[bench,ROOT/'scripts/check_live16_xsim.ps1']
        dependencies += [ROOT/'build/das4/fw'/p for p in ('itcm.hex','dtcm.hex','steer_lut.hex')]
        dependencies += [ROOT/'build/location_robustness/debug4_pcm.hex']
        if any(p.stat().st_mtime_ns>kernel.stat().st_mtime_ns for p in dependencies):raise SystemExit('UI_LIVE_PACKAGE_FAIL: stale four-mic simulation')
        fw_sources=[ROOT/'sw/fw'/p for p in ('start.S','fw_live.c','fw_fft.c','fw_gcc.c','fw_tables.c','fw_srp.c','link.ld')]+list((ROOT/'sw/fw').glob('*.h'))
        fw_sources.append(ROOT/'build/das4/fw/fw_debug4_geometry.h')
        if any(p.stat().st_mtime_ns>(ROOT/names[1]).stat().st_mtime_ns for p in fw_sources):raise SystemExit('UI_LIVE_PACKAGE_FAIL: stale RV32 firmware')
        acceptance=re.search(r'LIVE4_QUALITY_SOC_PASS frames=(\d+) samples=(\d+) dc_rejected=1 reacquired=1 drops=0',read(log))
        if not acceptance:raise SystemExit('UI_LIVE_PACKAGE_FAIL: missing four-mic rejection/reacquisition measurements')
    result = {
        'abi': '0x380 FIFO: low int16 DAS, high int16 FIR; 256 entries',
        'position_association': 'unavailable; never assign latest SRP grid to old audio',
        'sample_counter': 'relative to PS consumption session, not ADC hardware timestamp',
        'timing': {'setup_ns':float(timing[1]),'hold_ns':float(timing[5])},
        'board_tested': False,
        'active_channels': 4 if debug4 else 8,
        'geometry': json.loads((ROOT/'configs/debug4_geometry.json').read_text()) if debug4 else None,
        'localization_quality': {'magic':'LQT1','minimum_peak_separation_permille':20,'noise_or_invalid_returns_no_location':True} if debug4 else None,
        'simulation': {'frames':int(acceptance[1]),'continuous_audio_samples':int(acceptance[2]),'audio_drops':0,
                       'pcm_injected_after_pdm':True,'log_sha256':digest(log.read_bytes())} if debug4 else None,
        'firmware_sources':[{'path':str(p.relative_to(ROOT)).replace('\\','/'),'sha256':digest(p.read_bytes())} for p in fw_sources] if debug4 else [],
        'artifacts':[{'path':name,'sha256':digest((ROOT/name).read_bytes()),'bytes':(ROOT/name).stat().st_size} for name in names],
        'ui_sources':[{'path':'sw/'+name,'sha256':digest((ROOT/'sw'/name).read_bytes())} for name in ui_sources],
    }
    destination = ROOT/('build/das4/ui_live_release_manifest.json' if debug4 else 'build/ui_live_release_manifest.json')
    destination.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('UI_LIVE_PACKAGE_PASS: '+str(destination))

if __name__ == '__main__':
    main()
