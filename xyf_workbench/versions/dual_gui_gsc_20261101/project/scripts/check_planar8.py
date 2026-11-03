"""Exercise the production board's geometry, shared PDM, packing and DAS paths."""
import json
import math
from pathlib import Path
import subprocess
import re
from build_planar8 import geometry

ROOT = Path(__file__).resolve().parents[1]


def main():
    config = json.loads((ROOT/'configs/production_array.json').read_text())
    srp, steer = geometry(config)
    assert config['din_pins'] == ['T14', 'Y17', 'W16', 'T15']
    assert config['capture_bytes_per_bank'] == 512*4*4
    constraints = (ROOT/'constrs/ps_pl_wrapper.xdc').read_text(encoding='utf-8')
    pins = dict((int(i), pin) for pin, i in re.findall(
        r'PACKAGE_PIN (\w+)[^\n]*\{pdm_din_i\[(\d+)\]\}', constraints))
    assert pins == dict(enumerate(config['din_pins']))
    assert 'PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports rst_n]' in constraints
    assert 'PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports pdm_clk_o]' in constraints
    assert len(srp) == 28*1024 and len(steer) == 8*1024
    # Confirm front-view channel numbering and signs independently of LUT packing.
    xyz = config['channel_positions_m']
    for row in range(4):
        left, right = xyz[2*row:2*row+2]
        assert left[0] < right[0] and left[1] == right[1]
        assert math.isclose(right[0]-left[0], .048386)
        if row:
            assert math.isclose(xyz[2*row-2][1]-left[1], .024138)
    # Reflection changes x/y delays as expected; planar z reflection is ambiguous.
    fs = config['sample_rate_hz']/config['sound_speed_m_s']
    for point in [(.12,.08,.3), (-.12,-.08,.3)]:
        d = [math.dist(point, m)*fs for m in xyz]
        assert (d[0]-d[1])*point[0] > 0
        assert (d[0]-d[6])*point[1] < 0
    out = ROOT/'build/planar8_checks'
    out.mkdir(parents=True, exist_ok=True)
    coeff = re.search(r'fw_fir_coeff\[32\]\s*=\s*\{([^}]+)',
                      (ROOT/'sw/fw/fw_fir_coeff.h').read_text())[1]
    h = [int(v) for v in coeff.split(',') if v.strip()]
    (ROOT/'build/fw_fir_coeff.hex').write_text(''.join(f'{v & 65535:04x}\n' for v in h))
    # The legacy RTL uses forward declarations rejected by current Icarus.
    # Move declarations only in simulation copies, preserving all assignments.
    forward = {
        'rv32_overlap_localizer.v': ['wr_active', 'wr_word'],
        'rv32_soc.v': ['led_q', 'mmio_offset', 'mmio_write', 'loc_fault', 'recovery_state', 'pdm_capture_rdata', 'beam_fir_valid',
                      'beam_fir_sample', 'pdm_valid_aligned', 'pdm_frame_cnt', 'pdm_aligned'],
        'rv32_core.v': ['vec_hw_stall', 'audio_own'],
        'rv32_execute_stage.v': ['acou_sel', 'fft_sel'],
        'rv32_decoder.v': ['imm_gen_out'],
        'rv32_xsp_regs.v': ['out_valid_o', 'bin_o', 'pi_o'],
        'rv32_fft_bfly.v': ['rz_mr_q', 'xr2', 'rz_k', 'rz_m', 'xr'],
        'rv32_steer_regs.v': ['Q_IDLE', 'seq_q', 'm_q', 'geo_start'],
    }
    sources = []
    for p in (ROOT/'rtl').rglob('*.v'):
        if p.name not in forward:
            sources.append(str(p))
            continue
        s = p.read_text(encoding='utf-8')
        declarations = []
        for name in forward[p.name]:
            pattern = r'\b(?:wire|reg|localparam)\b[^;]*;'
            match = next((m for m in re.finditer(pattern, s)
                          if re.search(r'\b'+name+r'\b', m[0].split('=')[0])), None)
            assert match, (p, name)
            statement = match[0]
            if re.match(r'\s*wire\b', statement) and '=' in statement:
                # Net declaration assignments must stay in their original position.
                left, rhs = statement.split('=', 1)
                if name in ('xr2', 'xr'):
                    other = 'xi2' if name == 'xr2' else 'xi'
                    declarations.append('wire signed [15:0] '+name+', '+other+';')
                    replacement = 'assign '+name+' = '+re.sub(r',\s*'+other+r'\s*=', '; assign '+other+' =', rhs)
                else:
                    declarations.append(left.strip()+';')
                    replacement = 'assign '+name+' = '+rhs
            else:
                declarations.append(statement)
                replacement = ''
            s = s[:match.start()]+replacement+s[match.end():]
        insert = s.index(');', s.index('module '))+2
        s = s[:insert]+'\n'+'\n'.join(declarations)+'\n'+s[insert:]
        copy = out/p.name
        copy.write_text(s, encoding='utf-8')
        sources.append(str(copy))
    for top, marker in [('tb_srp_profiles', 'SRP_PROFILES_PASS'),
                        ('tb_planar8_overlap', 'PLANAR8_OVERLAP_PASS'),
                        ('tb_pdm_array_rx', 'PASS:'), ('tb_pdm_capture', 'PASS:'),
                        ('tb_das_stream', 'DAS_STREAM_PASS')]:
        exe = out/(top+'.vvp')
        cmd = ['iverilog', '-g2012', '-Irtl', '-s', top, '-o', str(exe),
               *sources, 'tb/'+top+'.v']
        # Capture TB shares the independent CIC/PDM reference models.
        if top == 'tb_pdm_capture':
            cmd.append('tb/tb_pdm_array_rx.v')
        q = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        (out/(top+'_compile.log')).write_text(q.stdout+q.stderr)
        assert q.returncode == 0, q.stderr[-5000:]
        q = subprocess.run(['vvp', str(exe)], cwd=ROOT, capture_output=True, text=True)
        (out/(top+'.log')).write_text(q.stdout+q.stderr)
        assert q.returncode == 0 and marker in q.stdout and 'FAIL:' not in q.stdout, q.stdout[-4000:]
        print(top+': PASS', flush=True)
    exe = out/'mic_levels.exe'
    subprocess.run(['gcc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-function',
                    'sw/ps_mic_levels_test.c', '-lm', '-o', str(exe)], cwd=ROOT, check=True)
    subprocess.run([str(exe)], cwd=ROOT, check=True)
    print('PLANAR8_CHECK_PASS', flush=True)


if __name__ == '__main__':
    main()
