"""Build the confirmed four-DIN planar board; no legacy circular-array LUTs."""
import argparse
import hashlib
import itertools
import json
import math
from pathlib import Path
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def geometry(config):
    assert config['channels'] == 8 and config['data_lines'] == 4
    assert config['mics_per_line'] == 2 and config['pairs'] == 28
    assert config['physical_mapping_confirmed']
    mapping = config['channel_to_mic']
    assert sorted(mapping) == list(range(8))
    mics = [config['mic_xyz'][m] for m in mapping]
    assert mics == config['channel_positions_m']
    fs, c = config['sample_rate_hz'], config['sound_speed_m_s']
    half, z = config['grid_half_m'], config['plane_z_m']
    assert z > 0, 'Planar array searches only the front hemisphere'
    grids = [(-half+2*half*x/31, -half+2*half*y/31, z)
             for y in range(32) for x in range(32)]
    delays = [[math.dist(p, m)*fs/c for m in mics] for p in grids]
    pairs = list(itertools.combinations(range(8), 2))
    srp, steer = [], []
    for a, b in pairs:
        for d in delays:
            q = math.floor((d[a]-d[b])*16)
            assert -256 <= q <= 239, '32-lag ring cannot cover interpolation'
            srp.append(q & 511)
    for m in range(8):
        for d in delays:
            steer.append(math.floor((d[0]-d[m])*16) & 16383)
    return srp, steer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compiler-prefix', default='riscv64-unknown-elf-')
    parser.add_argument('--geometry-only', action='store_true')
    args = parser.parse_args()
    config = json.loads((ROOT/'configs/production_array.json').read_text(encoding='utf-8'))
    srp, steer = geometry(config)
    out = ROOT/'build/das8'
    out.mkdir(parents=True, exist_ok=True)
    for name, values in [('srp_lut', srp), ('steer_lut', steer)]:
        (out/(name+'.hex')).write_bytes(''.join(f'{v:04x}\n' for v in values).encode())
    (out/'profile.json').write_text(json.dumps(config, indent=2)+'\n')
    if args.geometry_only:
        print('PLANAR8_GEOMETRY_PASS channels=8 lines=4 pairs=28 grid=1024')
        return
    tools = {n: shutil.which(args.compiler_prefix+n) for n in ('gcc', 'objcopy', 'size')}
    if not all(tools.values()):
        raise RuntimeError('RISC-V tools missing; supply --compiler-prefix including tool directory')
    from build_live16 import fft_rom
    fft_rom()
    fw = out/'fw'
    fw.mkdir(exist_ok=True)
    def run(*items):
        subprocess.run([str(x) for x in items], cwd=ROOT, check=True)
    flags = ['-march=rv32im_zicsr', '-mabi=ilp32', '-Os', '-ffreestanding',
             '-fno-builtin', '-nostdlib', '-Wall', '-Wextra', '-Werror',
             '-ffunction-sections', '-fdata-sections', '-fstack-usage',
             '-DFW_ARRAY_CHANNELS=8', '-DFW_GEOMETRY_CONFIRMED=1', '-DFW_VFFT_SEEK=1']
    objects = []
    for source in ('start.S', 'fw_planar8.c', 'fw_tables.c'):
        obj = fw/(Path(source).stem+'.o')
        run(tools['gcc'], *flags, '-c', ROOT/'sw/fw'/source, '-o', obj)
        objects.append(obj)
    elf = fw/'fw_planar8.elf'
    run(tools['gcc'], '-march=rv32im_zicsr', '-mabi=ilp32', '-nostdlib',
        '-T', ROOT/'sw/fw/link_live16.ld', '-Wl,--gc-sections,-Map='+str(fw/'fw_planar8.map'),
        *objects, '-o', elf)
    header = ['#ifndef ACOUSTIC_PLANAR8_IMAGE_H', '#define ACOUSTIC_PLANAR8_IMAGE_H',
              '#include <stdint.h>', '#define ACOUSTIC_ARRAY_CHANNELS 8u',
              '#define ACOUSTIC_ARRAY_PAIRS 28u', '#define ACOUSTIC_GEOMETRY_CONFIRMED 1u']
    arrays = {}
    for memory, section in [('itcm', '.text'), ('dtcm', '.data')]:
        binary = fw/(memory+'.bin')
        run(tools['objcopy'], '-O', 'binary', '--only-section='+section, elf, binary)
        data = binary.read_bytes()
        data += b'\0'*(-len(data) % 4)
        if not data:
            data = b'\0'*4
        assert len(data) <= 16384, 'TCM overflow'
        values = struct.unpack('<'+'I'*(len(data)//4), data)
        encoded = ''.join(f'{v:08x}\n' for v in values).encode()
        (fw/(memory+'.hex')).write_bytes(encoded)
        header += [f'#define ACOUSTIC_{memory.upper()}_WORDS {len(values)}u',
                   f'#define ACOUSTIC_{memory.upper()}_SHA256 "{hashlib.sha256(encoded).hexdigest()}"']
        arrays['acoustic_'+memory] = values
    coeff = re.search(r'fw_fir_coeff\[32\]\s*=\s*\{([^}]+)',
                      (ROOT/'sw/fw/fw_fir_coeff.h').read_text())[1]
    arrays['acoustic_fir_coeff'] = [int(v)&65535 for v in coeff.split(',') if v.strip()]
    arrays.update(acoustic_srp_lut=srp, acoustic_steer_lut=steer)
    header += ['#define ACOUSTIC_FIR_COEFF_WORDS 32u',
               '#define ACOUSTIC_SRP_LUT_WORDS 28672u', '#define ACOUSTIC_STEER_LUT_WORDS 8192u']
    for name, values in arrays.items():
        header.append(f'static const uint32_t {name}[{len(values)}]={{')
        header.extend(','.join(f'0x{v:08x}u' for v in values[i:i+8])+',' for i in range(0,len(values),8))
        header.append('};')
    header.append('#endif')
    (ROOT/'sw/acoustic_planar8_image.h').write_bytes(('\n'.join(header)+'\n').encode())
    (out/'build_manifest.json').write_text(json.dumps({
        'channels': 8, 'flags': flags, 'board_tested': False,
        'scheduler': 'cpu_custom_instructions_autonomous_transfers',
        'localizer_abi': 'P8O1', 'result_offset_cycles': 0,
        'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in [ROOT/'configs/production_array.json', Path(__file__),
                              ROOT/'scripts/create_zynq_project.tcl',
                              ROOT/'scripts/apply_pdm_constraints.tcl',
                              ROOT/'constrs/ps_pl_wrapper.xdc',
                              *sorted((ROOT/'sw/fw').glob('*.[ch]')),
                              ROOT/'sw/fw/start.S', ROOT/'sw/fw/link_live16.ld',
                              *sorted((ROOT/'rtl').rglob('*.v')),
                              *sorted((ROOT/'rtl').rglob('*.vh'))]},
        'elf_sha256': hashlib.sha256(elf.read_bytes()).hexdigest()}, indent=2)+'\n')
    run(tools['size'], elf)
    print('PLANAR8_BUILD_PASS channels=8 lines=4 pairs=28 geometry_enabled=1 board_tested=0')


if __name__ == '__main__':
    main()
