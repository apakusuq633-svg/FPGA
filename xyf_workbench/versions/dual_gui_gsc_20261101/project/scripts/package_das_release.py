"""Verify and fingerprint the DAS/FIR artifacts; never treats simulation as board proof."""
from pathlib import Path
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_log(name):
    data = (ROOT/name).read_bytes()
    encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig'
    return data.decode(encoding, errors='replace')


def main():
    flow = read_log('build/das_fir_zynq_console.log')
    release = read_log('build/das_release.log')
    acoustic = read_log('build/acoustic_rtl.log')
    negative = read_log('build/acoustic_fir_negative.log')
    if 'FLOW_PASS:' not in flow or 'FLOW_FAIL:' in flow or 'DAS_RELEASE_SIM_PASS' not in release:
        raise SystemExit('DAS_PACKAGE_FAIL: implementation/release gate is missing')
    for marker in ('ACOUSTIC_RTL_PASS', 'PDM_DAS_FIR_PASS', 'LIVE_LOCALIZATION_PASS',
                   'LIVE_SEQUENCE_REJECTED error=2 snapshots=0'):
        if marker not in acoustic:
            raise SystemExit('DAS_PACKAGE_FAIL: ' + marker)
    if 'ACOUSTIC_RTL_FAIL' not in negative or '[FAIL] acoustic result at 0x000038c8' not in negative:
        raise SystemExit('DAS_PACKAGE_FAIL: FIR negative control did not fail')

    checkpoint = ROOT / 'build/das_fir_routed.dcp'
    for source in list((ROOT/'rtl').rglob('*.v')) + list((ROOT/'constrs').glob('*.xdc')):
        if source.stat().st_mtime_ns > checkpoint.stat().st_mtime_ns:
            raise SystemExit('DAS_PACKAGE_FAIL: source newer than implementation: ' + str(source))
    for stem, header in (('fw', 'acoustic_image.h'), ('fw_live', 'acoustic_live_image.h')):
        text = (ROOT / 'sw' / header).read_text()
        for memory in ('itcm', 'dtcm'):
            digest = re.search(r'ACOUSTIC_' + memory.upper() + r'_SHA256 "([0-9a-f]{64})"', text)
            if not digest or digest[1] != sha(ROOT / 'sw/fw' / f'{stem}_{memory}.hex'):
                raise SystemExit('DAS_PACKAGE_FAIL: stale ' + header + ' ' + memory)
    report = (ROOT/'build/timing_zynq.rpt').read_text()
    timing = re.search(r'^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s', report, re.M)
    if not timing or float(timing[1]) < 0 or float(timing[5]) < 0 or int(timing[3]) or int(timing[7]):
        raise SystemExit('DAS_PACKAGE_FAIL: setup/hold violation')

    bit = ROOT/'build/das_fir_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit'
    xsa = ROOT/'build/das_fir.xsa'
    with zipfile.ZipFile(xsa) as archive:
        bits = [name for name in archive.namelist() if name.endswith('.bit')]
        if len(bits) != 1 or hashlib.sha256(archive.read(bits[0])).hexdigest() != sha(bit):
            raise SystemExit('DAS_PACKAGE_FAIL: XSA does not contain the released bitstream')
    names = [
        'build/das_fir.xsa', 'build/das_fir_routed.dcp',
        'build/das_fir_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit',
        'build/das_fir_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl',
        'build/acoustic_arm/acoustic_ddr.elf', 'build/acoustic_arm/live_das.elf',
        'build/ps_only_arm/ps_only.elf', 'sw/fw/fw.elf', 'sw/fw/fw_live.elf',
        'sw/fw/fw_itcm.hex', 'sw/fw/fw_dtcm.hex', 'sw/fw/fw_live_itcm.hex', 'sw/fw/fw_live_dtcm.hex',
        'sw/acoustic_image.h', 'sw/acoustic_live_image.h',
        'build/timing_zynq.rpt', 'build/util_zynq.rpt', 'build/io_zynq.rpt',
        'build/das_release.log', 'build/acoustic_rtl.log', 'build/acoustic_fir_negative.log',
        'build/das_stream.log', 'build/das_structure.log', 'build/das_pdm_window.log',
        'build/das_whole_machine.log',
    ]
    artifacts = [{'path': name, 'bytes': (ROOT/name).stat().st_size, 'sha256': sha(ROOT/name)}
                 for name in names]
    sources = list((ROOT/'rtl').rglob('*.v')) + list((ROOT/'constrs').glob('*.xdc'))
    sources += [ROOT/name for name in ('sw/ps_main.c', 'sw/ps_live.c', 'sw/fw/fw_main.c',
                                      'sw/fw/fw_live.c', 'sw/fw/fw_fir.c', 'sw/fw/fw_fir_coeff.h')]
    manifest = {
        'architecture': {'microphones': 8, 'simd_lanes': 8, 'pl_hz': 40000000,
                         'pcm_hz': 39062.5, 'fir_taps': 32, 'srp_pairs': 4, 'srp_grid': 256},
        'timing': {'setup_ns': float(timing[1]), 'hold_ns': float(timing[5]),
                   'setup_failing_endpoints': int(timing[3]), 'hold_failing_endpoints': int(timing[7])},
        'simulation_pass': True, 'arm_artifacts_packaged': True,
        'board_tested': False, 'board_reason': 'User confirmed hardware is not connected.',
        'io_timing_scope': 'Internal STA passes. PDM false paths use a separate analytical sampling-window budget; board and cable timing remain unverified.',
        'artifacts': artifacts,
        'sources': [{'path': path.relative_to(ROOT).as_posix(), 'sha256': sha(path)} for path in sorted(sources)],
    }
    destination = ROOT/'build/das_fir_release_manifest.json'
    destination.write_text(json.dumps(manifest, indent=2)+'\n', encoding='ascii')
    print('DAS_PACKAGE_PASS: ' + str(destination))


if __name__ == '__main__':
    main()
