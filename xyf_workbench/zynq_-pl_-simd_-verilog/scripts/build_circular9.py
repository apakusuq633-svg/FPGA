"""Build the proposed 9-microphone profile without asserting hardware acceptance."""
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


def geometry(c):
    expected = dict(channels=9, algorithm_channels=9, physical_mics=9,
                    capture_slots=10, data_lines=5, active_mask=511, pairs=36,
                    mics_per_line=2, grid_w=32, grid_count=1024, r_len=64,
                    pdm_decimation=16, window_samples=1024, localizer_hop=512)
    for key, value in expected.items():
        if c[key] != value:
            raise ValueError(f'{key}: expected {value}')
    if c['sample_rate_hz'] != c['pdm_clock_hz']/c['pdm_decimation'] or c['sample_rate_hz'] != c['sample_rate_num']/c['sample_rate_den']:
        raise ValueError('PDM/PCM sampling contract mismatch')
    xyz = c['channel_positions_m']
    if len(xyz) != 9 or xyz[8] != [0, 0, 0] or c['channel_to_mic'] != list(range(9)):
        raise ValueError('Expected M0..M7 ring, M8 center')
    for i, p in enumerate(xyz[:8]):
        wanted = (c['ring_radius_m']*math.cos(i*math.pi/4),
                  c['ring_radius_m']*math.sin(i*math.pi/4), 0)
        if math.dist(p, wanted) > 1e-9:
            raise ValueError('Nominal geometry does not match circular profile')
    if c['plane_z_m'] <= 0 or c['ring_radius_m'] >= c['pcb_radius_m']:
        raise ValueError('Invalid front scan plane or board clearance')
    if c['capture_bytes_per_bank'] != 512*5*4:
        raise ValueError('Capture packing mismatch')
    half, z = c['grid_half_m'], c['plane_z_m']
    grid = [(-half+2*half*x/31, -half+2*half*y/31, z)
            for y in range(32) for x in range(32)]
    delays = [[math.dist(p, m)*c['sample_rate_hz']/c['sound_speed_m_s'] for m in xyz] for p in grid]
    srp, steer = [], []
    pairs = list(itertools.combinations(range(9), 2))
    for a, b in pairs:
        for d in delays:
            q = math.floor((d[a]-d[b])*16)
            if not -c['r_len']*8 <= q < (c['r_len']//2-1)*16:
                raise ValueError('Correlation interpolation overflow')
            srp.append(q & (c['r_len']*16-1))
    for m in range(9):
        for d in delays:
            steer.append(math.floor((d[0]-d[m])*16) & 16383)
    return srp, steer, pairs


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--compiler-prefix', default='D:/AMDDesignTools/2025.2/gnu/riscv/nt/bin/riscv64-unknown-elf-')
    p.add_argument('--geometry-only', action='store_true')
    p.add_argument('--reference-post', action='store_true', help='build the slower equivalent postprocessor for comparison')
    p.add_argument('--test-geometry', action='store_true', help='simulation-only approved geometry image; never replaces the production header')
    a = p.parse_args()
    config_path = ROOT/'configs/circular9_array.json'
    c = json.loads(config_path.read_text(encoding='utf-8'))
    srp, steer, pairs = geometry(c)
    profile = {'SAMPLE_RATE_NUM':c['sample_rate_num'], 'SAMPLE_RATE_DEN':c['sample_rate_den'],
               'PDM_DECIM':c['pdm_decimation'], 'LOCALIZER_HOP':c['localizer_hop'],
               'CORRELATION_LAGS':c['r_len'], 'WINDOW_SAMPLES':1024,
               'DIAGNOSTIC_SAMPLE_RATE_NUM':78125, 'DIAGNOSTIC_SAMPLE_RATE_DEN':2,
               'DIAGNOSTIC_DECIM':c['diagnostic_decimation']}
    (ROOT/'sw/circular9_profile.h').write_text('#ifndef CIRCULAR9_PROFILE_H\n#define CIRCULAR9_PROFILE_H\n'+
        ''.join(f'#define ACOUSTIC_{key} {value}u\n' for key,value in profile.items())+'#endif\n',encoding='ascii')
    out = ROOT/'build/circular9'
    out.mkdir(parents=True, exist_ok=True)
    for name, values in [('srp_lut', srp), ('steer_lut', steer)]:
        (out/(name+'.hex')).write_text(''.join(f'{v:04x}\n' for v in values), encoding='ascii', newline='\n')
    (out/'profile.json').write_text(json.dumps(c, indent=2)+'\n', encoding='utf-8')
    (out/'pairs.json').write_text(json.dumps(pairs)+'\n', encoding='ascii')
    if a.geometry_only:
        print('CIRCULAR9_GEOMETRY_PASS channels=9 slots=10 pairs=36 grid=1024')
        return
    compiler = {n: shutil.which(a.compiler_prefix+n) for n in ('gcc', 'objcopy', 'size')}
    if not all(compiler.values()):
        raise RuntimeError('RISC-V toolchain missing')
    from build_live16 import fft_rom
    fft_rom()
    if a.reference_post and a.test_geometry:raise ValueError('Choose one comparison fixture')
    fw = out/('fw_test' if a.test_geometry else 'fw_reference' if a.reference_post else 'fw')
    fw.mkdir(exist_ok=True)
    confirmed = int(a.test_geometry or (c['physical_mapping_confirmed'] and c['geometry_status'] != 'proposed'))
    flags = ['-march=rv32im_zicsr', '-mabi=ilp32', '-Os', '-ffreestanding',
             '-fno-builtin', '-nostdlib', '-Wall', '-Wextra', '-Werror',
             '-ffunction-sections', '-fdata-sections', '-fstack-usage',
             '-DFW_ARRAY_CHANNELS=9', f'-DFW_GEOMETRY_CONFIRMED={confirmed}', '-DFW_VFFT_SEEK=1',
             f'-DFW_FAST_POST={int(not a.reference_post)}']
    def run(*cmd):
        subprocess.run(list(map(str, cmd)), cwd=ROOT, check=True)
    objects = []
    for name in ('start.S', 'fw_planar8.c', 'fw_tables.c'):
        obj = fw/(Path(name).stem+'.o')
        run(compiler['gcc'], *flags, '-c', ROOT/'sw/fw'/name, '-o', obj)
        objects.append(obj)
    elf = fw/'fw_circular9.elf'
    run(compiler['gcc'], '-march=rv32im_zicsr', '-mabi=ilp32', '-nostdlib',
        '-T', ROOT/'sw/fw/link_live16.ld', '-Wl,--gc-sections,-Map='+str(fw/'fw_circular9.map'),
        *objects, '-o', elf)
    header = ['#ifndef ACOUSTIC_CIRCULAR9_IMAGE_H', '#define ACOUSTIC_CIRCULAR9_IMAGE_H',
              '#include <stdint.h>', '#include "circular9_profile.h"', '#define ACOUSTIC_ARRAY_CHANNELS 9u',
              '#define ACOUSTIC_CAPTURE_SLOTS 10u', '#define ACOUSTIC_ACTIVE_MASK 0x1ffu',
              '#define ACOUSTIC_ARRAY_PAIRS 36u', f'#define ACOUSTIC_GEOMETRY_CONFIRMED {confirmed}u']
    header += [f'#define ACOUSTIC_GEOMETRY_VERSION 0x{hashlib.sha256(config_path.read_bytes()).hexdigest()[:8]}u',
               f'#define ACOUSTIC_CALIBRATION_VERSION {int(c.get("calibration_version",0))}u']
    arrays = {}
    for mem, section in [('itcm', '.text'), ('dtcm', '.data')]:
        binary = fw/(mem+'.bin')
        run(compiler['objcopy'], '-O', 'binary', '--only-section='+section, elf, binary)
        data = binary.read_bytes()
        data += b'\0'*(-len(data) % 4)
        data = data or b'\0'*4
        if len(data) > 16384:
            raise RuntimeError('TCM overflow')
        words = struct.unpack('<'+'I'*(len(data)//4), data)
        encoded = ''.join(f'{v:08x}\n' for v in words).encode()
        (fw/(mem+'.hex')).write_bytes(encoded)
        header += [f'#define ACOUSTIC_{mem.upper()}_WORDS {len(words)}u',
                   f'#define ACOUSTIC_{mem.upper()}_SHA256 "{hashlib.sha256(encoded).hexdigest()}"']
        arrays['acoustic_'+mem] = words
    # Same physical 10 kHz low-pass cutoff at the new PCM rate. PS uses these
    # exact coefficients to check the PL beam; diagnosis has its own 4:1 filter.
    fc=10000/c['sample_rate_hz']
    taps=[math.sin(2*math.pi*fc*(n-15.5))/(math.pi*(n-15.5))*(.54-.46*math.cos(2*math.pi*n/31)) for n in range(32)]
    coeff=[round(v/sum(taps)*32768) for v in taps]
    correction=32768-sum(coeff);coeff[15]+=correction//2;coeff[16]+=correction-correction//2
    arrays['acoustic_fir_coeff'] = [v&65535 for v in coeff]
    arrays.update(acoustic_srp_lut=srp, acoustic_steer_lut=steer)
    for name, values in arrays.items():
        if name not in ('acoustic_itcm', 'acoustic_dtcm'):
            header.append(f'#define {name.upper()}_WORDS {len(values)}u')
        header.append(f'static const uint32_t {name}[{len(values)}]={{')
        header.extend(','.join(f'0x{v:08x}u' for v in values[i:i+8])+',' for i in range(0,len(values),8))
        header.append('};')
    header.append('#endif')
    header_path = out/'acoustic_circular9_TEST_ONLY.h' if a.test_geometry else out/'acoustic_circular9_reference.h' if a.reference_post else ROOT/'sw/acoustic_circular9_image.h'
    header_path.write_text('\n'.join(header)+'\n', encoding='ascii', newline='\n')
    deps = [config_path, Path(__file__), ROOT/'sw/fw/fw_planar8.c',
            *sorted((ROOT/'rtl').rglob('*.v')), *sorted((ROOT/'sw/fw').glob('*.h'))]
    (out/('TEST_ONLY_manifest.json' if a.test_geometry else 'reference_manifest.json' if a.reference_post else 'build_manifest.json')).write_text(json.dumps(dict(
        channels=9, capture_slots=10, pairs=36, board_tested=False,
        simulation_only=a.test_geometry,
        geometry_confirmed=bool(confirmed), flags=flags, localizer_abi='P9D2',
        sample_rate_hz=c['sample_rate_hz'],pdm_decimation=c['pdm_decimation'],
        window_samples=1024,hop_samples=c['localizer_hop'],correlation_lags=c['r_len'],
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in deps},
        elf_sha256=hashlib.sha256(elf.read_bytes()).hexdigest()), indent=2)+'\n')
    run(compiler['size'], elf)
    print('CIRCULAR9_BUILD_PASS channels=9 slots=10 pairs=36 board_tested=0')


if __name__ == '__main__':
    main()
