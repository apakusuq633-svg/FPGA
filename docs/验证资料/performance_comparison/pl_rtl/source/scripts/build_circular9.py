"""Build direction-only 9-microphone tables without asserting hardware acceptance."""
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
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
GEOMETRY_TOLERANCE_M = .0005
CALIBRATION_ROLES = {'gain', 'delay', 'fit'}
CAPTURE_BINDING_KEYS = ('pdm_clock_hz', 'pdm_decimation', 'sample_rate_hz',
                       'sample_rate_num', 'sample_rate_den', 'pl_clock_hz',
                       'active_mask', 'capture_slots', 'window_samples',
                       'localizer_hop', 'r_len', 'diagnostic_decimation')


def canonical_sha256(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                    allow_nan=False).encode('utf-8')).hexdigest()


def finite_number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(name+': expected a finite number')
    return value


def calibration_parameters(c):
    """Relative sensor arrival offsets are added before all pair differences.

    gain_q14 is a positive signed16 Q2.14 correction; 32768 would be negative
    in the real aligner. Missing unmeasured coefficients preserve unity/zero.
    """
    gain = c.get('channel_gain_q14', [16384]*9)
    delay = c.get('channel_delay_samples', [0]*9)
    if not isinstance(gain, list) or len(gain) != 9 or any(type(v) is not int or not 8192 <= v <= 32767 for v in gain):
        raise ValueError('channel_gain_q14: nine signed16 positive Q2.14 gains in8192..32767 required')
    if not isinstance(delay, list) or len(delay) != 9:
        raise ValueError('channel_delay_samples: nine relative sensor delays required')
    for i, value in enumerate(delay):
        if abs(finite_number(value, f'channel_delay_samples[{i}]')) > 4:
            raise ValueError('Sensor delay exceeds four PCM samples')
    if delay[0] != 0:
        raise ValueError('Sensor delay reference channel0 must be zero')
    return gain, delay


def calibration_binding(c):
    gain, delay = calibration_parameters(c)
    return {'channel_positions_m': c['channel_positions_m'], 'channel_to_mic': c['channel_to_mic'],
            'channel_gain_q14': gain, 'channel_delay_samples': delay,
            'capture_contract': {key: c[key] for key in CAPTURE_BINDING_KEYS},
            'coordinate_unit': c.get('coordinate_unit'), 'coordinate_frame': c.get('coordinate_frame'),
            'sound_speed_m_s': c['sound_speed_m_s'], 'ring_radius_m': c['ring_radius_m'],
            'pcb_radius_m': c['pcb_radius_m'], 'band_low_hz': c['band_low_hz'],
            'band_high_hz': c['band_high_hz'], 'scan_model': c['scan_model']}


def geometry_confirmed(c):
    """An assertion in a JSON flag is insufficient: reviewed record must bind
    the measured geometry, mapping, sensor corrections and capture contract.
    Evidence hashes are retained here; the calibration CLI also checks files.
    This check is provenance validation, not proof that a human measured well.
    """
    measurement = c.get('geometry_measurement')
    if measurement is None:
        if c.get('calibration_version', 0) != 0 or c.get('calibration_status', 'unmeasured') != 'unmeasured' or c.get('geometry_status') == 'measured_confirmed':
            raise ValueError('Measured calibration requires a bound reviewed measurement record')
        return False
    if not isinstance(measurement, dict) or not isinstance(measurement.get('record'), dict):
        raise ValueError('Invalid geometry_measurement provenance')
    record = measurement['record']
    if measurement.get('record_sha256') != canonical_sha256(record) or measurement.get('binding_sha256') != canonical_sha256(calibration_binding(c)):
        raise ValueError('Measurement record or calibration binding SHA256 mismatch')
    if type(record.get('record_version')) is not int or record['record_version'] != 1 or not re.fullmatch(r'[0-9a-f]{64}', str(record.get('source_config_sha256', ''))):
        raise ValueError('Unsupported measurement record or source config digest')
    microphones = record.get('microphones')
    if not isinstance(microphones, list) or len(microphones) != 9:
        raise ValueError('Nine measured microphone entries required')
    positions = {}
    for entry in microphones:
        if not isinstance(entry, dict) or type(entry.get('mic_id')) is not int or entry['mic_id'] not in range(9) or entry['mic_id'] in positions:
            raise ValueError('Measured microphone IDs must uniquely cover0..8')
        positions[entry['mic_id']] = entry.get('position_m')
    mapped = [positions[m] for m in c['channel_to_mic']]
    contract = record.get('capture_contract')
    expected_contract = {key: c[key] for key in CAPTURE_BINDING_KEYS}
    if record.get('channel_to_mic') != c['channel_to_mic'] or mapped != c['channel_positions_m'] or contract != expected_contract or any(type(contract[key]) is not type(expected_contract[key]) for key in expected_contract):
        raise ValueError('Measurement geometry/mapping/capture contract differs from configuration')
    confirmations = record.get('confirmations', {})
    required = ('geometry_measured', 'channel_mapping_measured', 'clock_and_decimation_verified',
                'gain_delay_measured', 'fit_residuals_reviewed', 'accepted_for_build')
    if not isinstance(confirmations, dict) or any(key not in confirmations or type(confirmations[key]) is not bool for key in required):
        raise ValueError('Explicit boolean measurement confirmations required')
    reviewed = all(confirmations[key] for key in required)
    gain, delay = calibration_parameters(c)
    if reviewed:
        if record.get('channel_gain_q14') != gain or record.get('channel_delay_samples') != delay:
            raise ValueError('Reviewed sensor correction coefficients differ from configuration')
        for key in ('array_id', 'operator', 'measured_at'):
            if not isinstance(record.get(key), str) or not record[key].strip():
                raise ValueError('Reviewed record requires '+key)
        try:
            when = datetime.fromisoformat(record['measured_at'].replace('Z', '+00:00'))
        except ValueError as exc:
            raise ValueError('Measurement time must be ISO8601 with timezone') from exc
        if when.tzinfo is None or when.utcoffset() is None:
            raise ValueError('Measurement time must include timezone')
        sources = record.get('sources', {})
        if not isinstance(sources, dict) or any(not isinstance(sources.get(key), str) or not sources[key].strip() for key in ('geometry', 'mapping', 'clock', 'gain', 'delay')):
            raise ValueError('Reviewed geometry/mapping/clock/gain/delay sources required')
        evidence = record.get('evidence_files')
        roles = set()
        if not isinstance(evidence, list):
            raise ValueError('Evidence references required')
        for entry in evidence:
            if not isinstance(entry, dict) or not isinstance(entry.get('path'), str) or not entry['path'].strip() or not re.fullmatch(r'[0-9a-f]{64}', str(entry.get('sha256', ''))) or not isinstance(entry.get('roles'), list) or any(not isinstance(role, str) for role in entry['roles']):
                raise ValueError('Evidence requires path, SHA256 and role list')
            roles.update(entry['roles'])
        if not CALIBRATION_ROLES.issubset(roles):
            raise ValueError('Gain, delay and fit residuals must have evidence references')
        residual = record.get('fit_residuals', {})
        if not isinstance(residual, dict):
            raise ValueError('Band-limited fit residuals required')
        low = finite_number(residual.get('band_low_hz'), 'fit band low')
        high = finite_number(residual.get('band_high_hz'), 'fit band high')
        if low < 0 or low > 300 or high < c['band_high_hz'] or high >= c['sample_rate_hz']/2 or low >= high:
            raise ValueError('Fit evidence must cover at least300..configured high Hz')
        for name, limit in (('gain_rms_db', .5), ('phase_rms_deg', 10), ('delay_rms_samples', .25)):
            values = residual.get(name)
            if not isinstance(values, list) or len(values) != 9:
                raise ValueError('Nine per-channel '+name+' residuals required')
            if any(not 0 <= finite_number(value, name) <= limit for value in values):
                raise ValueError(name+' exceeds reviewed constant-gain/delay model limit')
    version = (int(canonical_sha256(record)[:8], 16) or 1) if reviewed else 0
    expected_status = 'measured_reviewed' if reviewed else 'unmeasured'
    if c.get('calibration_version', 0) != version or c.get('calibration_status', 'unmeasured') != expected_status or c.get('physical_mapping_confirmed') is not reviewed or c.get('geometry_status') != ('measured_confirmed' if reviewed else 'measured_unconfirmed'):
        raise ValueError('Calibration status/version/confirmation differs from reviewed record')
    return reviewed


def verify_calibration_evidence(c):
    """Reopen evidence at actual build time, after the independent math check.
    A prior successful CLI review is not permission to use changed files.
    Return absolute path->actual digest for the build/package allowlist.
    """
    measurement = c.get('geometry_measurement')
    if measurement is None:return {}
    record = measurement['record']
    evidence = record.get('evidence_files', [])
    if not isinstance(evidence, list):raise ValueError('Invalid evidence list')
    root_name = measurement.get('evidence_root')
    if not isinstance(root_name, str) or not Path(root_name).is_absolute():
        raise ValueError('Measured config requires absolute original evidence_root')
    root = Path(root_name)
    result = {}
    for entry in evidence:
        if not isinstance(entry, dict) or not isinstance(entry.get('path'), str) or not entry['path'] or not re.fullmatch(r'[0-9a-f]{64}', str(entry.get('sha256', ''))):
            raise ValueError('Build evidence requires actual path and SHA256')
        path = Path(entry['path'])
        if not path.is_absolute():path = root/path
        path = path.resolve()
        if not path.is_file():raise ValueError('Build measurement evidence missing: '+str(path))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != entry['sha256']:
            raise ValueError('Build measurement evidence SHA256 changed: '+str(path))
        if str(path) in result and result[str(path)] != digest:
            raise ValueError('Conflicting evidence references')
        result[str(path)] = digest
    return result


def direction_grid(c):
    """Front hemisphere: equal increments in azimuth and elevation.

    Cell centers avoid repeated poles and the z=0 front/back boundary.  The
    measured direction points FROM the array TO the source, so a plane wave
    arrives at microphone m at -dot(m,u)/c relative to the array center.
    """
    if (c.get('scan_model') != 'far_field_direction' or
        c.get('direction_grid') != 'uniform_azimuth_elevation_cell_centers' or
        c.get('azimuth_min_deg') != -90 or c.get('azimuth_max_deg') != 90 or
        c.get('elevation_min_deg') != -90 or c.get('elevation_max_deg') != 90 or
        c.get('front_hemisphere_only') is not True or
        c.get('planar_front_back_ambiguous') is not True or
        any(key in c for key in ('plane_z_m', 'grid_half_m'))):
        raise ValueError('Expected direction-only front hemisphere; no distance plane')
    width = c['grid_w']
    azimuth = [-90+180*(column+.5)/width for column in range(width)]
    elevation = [-90+180*(row+.5)/width for row in range(width)]
    vectors = [(math.cos(math.radians(e))*math.sin(math.radians(a)), math.sin(math.radians(e)),
                math.cos(math.radians(e))*math.cos(math.radians(a)))
               for e in elevation for a in azimuth]
    return vectors, azimuth, elevation


def plane_wave_delays(c, azimuth_deg, elevation_deg):
    """Arrival times in PCM samples; no source distance or common propagation delay."""
    a, e = math.radians(azimuth_deg), math.radians(elevation_deg)
    u = (math.cos(e)*math.sin(a), math.sin(e), math.cos(e)*math.cos(a))
    _, sensor_delay = calibration_parameters(c)
    return [-sum(m[k]*u[k] for k in range(3))*c['sample_rate_hz']/c['sound_speed_m_s']+sensor_delay[ch]
            for ch, m in enumerate(c['channel_positions_m'])]


def direction_header(c):
    vectors, azimuth, elevation = direction_grid(c)
    lines = ['/* Generated by scripts/build_circular9.py; direction only, no range. */',
        '#ifndef CIRCULAR9_DIRECTION_H', '#define CIRCULAR9_DIRECTION_H',
        '#include <stdint.h>', '#define C9_DIRECTION_COUNT 1024u',
        '#define C9_DIRECTION_WIDTH 32u', '#define C9_DIRECTION_FRONT_BACK_AMBIGUOUS 1u',
        '#define C9_DIRECTION_SCAN_MODEL "far_field_direction"']
    for name, values in [('azimuth', azimuth), ('elevation', elevation)]:
        lines += [f'static const int32_t c9_direction_{name}_mdeg[32]={{',
                  ','.join(str(round(value*1000)) for value in values), '};']
    lines.append('static const int32_t c9_direction_unit_q30[1024][3]={')
    lines += ['{'+','.join(str(round(value*(1 << 30))) for value in vector)+'},'
              for vector in vectors]
    lines += ['};',
        'static inline int c9_direction_from_grid(unsigned grid,int32_t *azimuth_mdeg,int32_t *elevation_mdeg){',
        ' if(grid>=C9_DIRECTION_COUNT)return 0;',
        ' if(azimuth_mdeg)*azimuth_mdeg=c9_direction_azimuth_mdeg[grid%C9_DIRECTION_WIDTH];',
        ' if(elevation_mdeg)*elevation_mdeg=c9_direction_elevation_mdeg[grid/C9_DIRECTION_WIDTH];',
        ' return 1;', '}',
        '/* Cosine of spherical separation in Q30; compare with cos(min_angle). */',
        'static inline int64_t c9_direction_dot_q30(unsigned a,unsigned b){',
        ' int64_t dot=0;unsigned k;',
        ' if(a>=C9_DIRECTION_COUNT||b>=C9_DIRECTION_COUNT)return -(INT64_C(1)<<30);',
        ' for(k=0;k<3;k++)dot+=(int64_t)c9_direction_unit_q30[a][k]*c9_direction_unit_q30[b][k];',
        ' dot=(dot+(INT64_C(1)<<29))>>30;',
        ' if(dot>(INT64_C(1)<<30))dot=INT64_C(1)<<30;',
        ' if(dot<-(INT64_C(1)<<30))dot=-(INT64_C(1)<<30);',
        ' return dot;', '}',
        'static inline int c9_direction_within(unsigned a,unsigned b,int32_t cosine_q30){',
        ' return a<C9_DIRECTION_COUNT&&b<C9_DIRECTION_COUNT&&c9_direction_dot_q30(a,b)>=cosine_q30;',
        '}', '#endif']
    return '\n'.join(lines)+'\n'


def geometry(c):
    expected = dict(channels=9, algorithm_channels=9, physical_mics=9,
                    capture_slots=10, data_lines=5, active_mask=511, pairs=36,
                    mics_per_line=2, grid_w=32, grid_count=1024, r_len=64,
                    pdm_decimation=16, window_samples=1024, localizer_hop=512)
    for key, value in expected.items():
        if type(c.get(key)) is not int or c[key] != value:
            raise ValueError(f'{key}: expected {value}')
    for key in ('sample_rate_hz', 'sample_rate_num', 'sample_rate_den', 'pdm_clock_hz', 'pdm_decimation', 'pl_clock_hz', 'sound_speed_m_s', 'pcb_radius_m', 'ring_radius_m'):
        if finite_number(c.get(key), key) <= 0:
            raise ValueError(key+': must be positive')
    for key in ('sample_rate_num', 'sample_rate_den', 'pdm_clock_hz', 'pl_clock_hz'):
        if type(c[key]) is not int:
            raise ValueError(key+': integer capture contract required')
    if c['sample_rate_hz'] != c['pdm_clock_hz']/c['pdm_decimation'] or c['sample_rate_hz'] != c['sample_rate_num']/c['sample_rate_den']:
        raise ValueError('PDM/PCM sampling contract mismatch')
    xyz, mapping = c.get('channel_positions_m'), c.get('channel_to_mic')
    if not isinstance(mapping, list) or len(mapping) != 9 or any(type(m) is not int for m in mapping) or set(mapping) != set(range(9)):
        raise ValueError('channel_to_mic must be a unique permutation0..8')
    if mapping[8] != 8:
        raise ValueError('Center mic8 must remain in capture slot8; correct physical wiring before calibration')
    if not isinstance(xyz, list) or len(xyz) != 9 or any(not isinstance(p, list) or len(p) != 3 for p in xyz):
        raise ValueError('Nine channel-order xyz coordinate triples required')
    for ch, point in enumerate(xyz):
        for axis, value in enumerate(point):finite_number(value, f'channel_positions_m[{ch}][{axis}]')
    if c.get('coordinate_unit') != 'm' or c.get('coordinate_frame') != 'front view +x right +y up +z toward observer':
        raise ValueError('Coordinates must use metres in the advertised front/right/up frame')
    if not .005 <= c['pcb_radius_m'] <= .05 or not .005 <= c['ring_radius_m'] <= c['pcb_radius_m']+GEOMETRY_TOLERANCE_M:
        raise ValueError('Array dimensions outside supported circular9 board envelope')
    if not 300 <= c['sound_speed_m_s'] <= 380:
        raise ValueError('Sound speed outside supported air calibration range')
    # Validate explicit acoustic centers against the PCB outline; the board
    # radius is not a sound-hole radius and outer centers need not be circular.
    if any(math.hypot(p[0], p[1]) > c['pcb_radius_m']+GEOMETRY_TOLERANCE_M for p in xyz):
        raise ValueError('Measured acoustic center lies outside board envelope/tolerance')
    if max(abs(p[2]) for p in xyz) > GEOMETRY_TOLERANCE_M or max(p[2] for p in xyz)-min(p[2] for p in xyz) > GEOMETRY_TOLERANCE_M:
        raise ValueError('Coordinates must lie in the xy acoustic plane within0.5mm')
    if math.hypot(xyz[8][0], xyz[8][1]) > .003:
        raise ValueError('Center mic8 lies more than3mm from coordinate origin')
    if any(math.dist(a, b) < .001 for a, b in itertools.combinations(xyz, 2)):
        raise ValueError('Coincident/near-coincident acoustic centers')
    radii = [math.hypot(p[0]-xyz[8][0], p[1]-xyz[8][1]) for p in xyz[:8]]
    if any(not .5*c['ring_radius_m'] <= r <= 1.5*c['ring_radius_m'] for r in radii):
        raise ValueError('Eight outer microphones must surround the central microphone')
    angles = sorted(math.atan2(p[1]-xyz[8][1], p[0]-xyz[8][0]) for p in xyz[:8])
    if max((angles[(i+1)%8]-angles[i]) % (2*math.pi) for i in range(8)) > math.radians(100):
        raise ValueError('Outer microphone geometry leaves an unsupported angular gap')
    mean = [sum(p[k] for p in xyz)/9 for k in range(2)]
    xx = sum((p[0]-mean[0])**2 for p in xyz);yy = sum((p[1]-mean[1])**2 for p in xyz)
    xy = sum((p[0]-mean[0])*(p[1]-mean[1]) for p in xyz)
    disc = math.hypot(xx-yy, 2*xy);large=(xx+yy+disc)/2;small=(xx+yy-disc)/2
    if large <= 0 or small < .1*large or max(math.dist(a, b) for a, b in itertools.combinations(xyz, 2)) < .015:
        raise ValueError('Acoustically degenerate or undersized two-dimensional aperture')
    calibration_parameters(c)
    geometry_confirmed(c)
    if c['capture_bytes_per_bank'] != 512*5*4:
        raise ValueError('Capture packing mismatch')
    _, azimuth, elevation = direction_grid(c)
    delays = [plane_wave_delays(c, a, e) for e in elevation for a in azimuth]
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
    p.add_argument('--validate-only', action='store_true', help='validate explicit configuration without writing generated products')
    p.add_argument('--config', type=Path, default=ROOT/'configs/circular9_array.json',
                   help='explicit nominal or measurement-bound calibrated configuration')
    p.add_argument('--reference-post', action='store_true', help='build the slower equivalent postprocessor for comparison')
    p.add_argument('--test-geometry', action='store_true', help='simulation-only approved geometry image; never replaces the production header')
    a = p.parse_args()
    config_path = a.config.resolve()
    config_bytes = config_path.read_bytes()
    config_sha256 = hashlib.sha256(config_bytes).hexdigest()
    c = json.loads(config_bytes.decode('utf-8'))
    gain, sensor_delay = calibration_parameters(c)
    c.setdefault('channel_gain_q14', gain)
    c.setdefault('channel_delay_samples', sensor_delay)
    c.setdefault('calibration_status', 'unmeasured')
    c.setdefault('calibration_version', 0)
    c.setdefault('clearance_unverified', True)
    srp, steer, pairs = geometry(c)
    evidence_sha256 = verify_calibration_evidence(c)
    if a.validate_only:
        print('CIRCULAR9_CONFIG_PASS config_sha256='+config_sha256+
              ' geometry_confirmed='+str(int(geometry_confirmed(c)))+' calibration_status='+c['calibration_status'])
        return
    (ROOT/'sw/circular9_direction.h').write_text(direction_header(c), encoding='ascii', newline='\n')
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
    confirmed = int(a.test_geometry or geometry_confirmed(c))
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
        '-T', ROOT/'sw/fw/link_live16.ld', '-Wl,--build-id=none,--gc-sections,-Map='+str(fw/'fw_circular9.map'),
        *objects, '-o', elf)
    header = ['#ifndef ACOUSTIC_CIRCULAR9_IMAGE_H', '#define ACOUSTIC_CIRCULAR9_IMAGE_H',
              '#include <stdint.h>', '#include "circular9_profile.h"', '#define ACOUSTIC_ARRAY_CHANNELS 9u',
              '#define ACOUSTIC_CAPTURE_SLOTS 10u', '#define ACOUSTIC_ACTIVE_MASK 0x1ffu',
              '#define ACOUSTIC_ARRAY_PAIRS 36u', f'#define ACOUSTIC_GEOMETRY_CONFIRMED {confirmed}u']
    header += [f'#define ACOUSTIC_GEOMETRY_VERSION 0x{config_sha256[:8]}u',
               f'#define ACOUSTIC_CALIBRATION_VERSION {int(c.get("calibration_version",0))}u',
               '#define ACOUSTIC_CALIBRATION_STATUS '+json.dumps(c['calibration_status'])]
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
    arrays.update(acoustic_srp_lut=srp, acoustic_steer_lut=steer, acoustic_gain_q14=gain+[0])
    for name, values in arrays.items():
        if name not in ('acoustic_itcm', 'acoustic_dtcm'):
            header.append(f'#define {name.upper()}_WORDS {len(values)}u')
        header.append(f'static const uint32_t {name}[{len(values)}]={{')
        header.extend(','.join(f'0x{v:08x}u' for v in values[i:i+8])+',' for i in range(0,len(values),8))
        header.append('};')
    header.append('#endif')
    header_path = out/'acoustic_circular9_TEST_ONLY.h' if a.test_geometry else out/'acoustic_circular9_reference.h' if a.reference_post else ROOT/'sw/acoustic_circular9_image.h'
    if hashlib.sha256(config_path.read_bytes()).hexdigest() != config_sha256:
        raise ValueError('Configuration changed during build; restart with one reviewed input')
    if verify_calibration_evidence(c) != evidence_sha256:
        raise ValueError('Measurement evidence changed during build')
    header_path.write_text('\n'.join(header)+'\n', encoding='ascii', newline='\n')
    deps = [config_path, Path(__file__), ROOT/'sw/fw/fw_planar8.c',
            *sorted((ROOT/'rtl').rglob('*.v')), *sorted((ROOT/'sw/fw').glob('*.h')),
            *(Path(path) for path in evidence_sha256)]
    (out/('TEST_ONLY_manifest.json' if a.test_geometry else 'reference_manifest.json' if a.reference_post else 'build_manifest.json')).write_text(json.dumps(dict(
        channels=9, capture_slots=10, pairs=36, board_tested=False,
        simulation_only=a.test_geometry,
        geometry_confirmed=bool(confirmed), flags=flags, localizer_abi='P9D2',
        sample_rate_hz=c['sample_rate_hz'],pdm_decimation=c['pdm_decimation'],
        window_samples=1024,hop_samples=c['localizer_hop'],correlation_lags=c['r_len'],
        scan_model=c['scan_model'], direction_grid=c['direction_grid'],
        config_path=str(config_path), config_sha256=config_sha256,
        calibration_evidence_sha256=evidence_sha256,
        calibration_status=c['calibration_status'], calibration_version=c['calibration_version'],
        source_sha256={str(p) if str(p) in evidence_sha256 else str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in deps},
        elf_sha256=hashlib.sha256(elf.read_bytes()).hexdigest()), indent=2)+'\n')
    run(compiler['size'], elf)
    print('CIRCULAR9_BUILD_PASS channels=9 slots=10 pairs=36 board_tested=0')


if __name__ == '__main__':
    main()
