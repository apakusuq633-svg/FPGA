"""Shared SRP configurations and 4/8/16 acoustic lanes; exact reference and negative controls."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/system_optimization'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    compiler = shutil.which('iverilog') or 'D:/iverilog/bin/iverilog.exe'
    runtime = shutil.which('vvp') or 'D:/iverilog/bin/vvp.exe'
    for generator in ['fw_acou_model.py', 'gen_srp_vectors.py']:
        subprocess.run(['python', str(ROOT/'scripts/golden'/generator)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['python', str(ROOT/'scripts/golden/gen_srp_vectors.py'), '--pairs', '4', '--grid-w', '16', '--out-prefix', 'srp4x256'],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    tests = [('tb_srp_throughput', [], ['rtl/srp/rv32_srp_scan.v'], 'SRP_THROUGHPUT_PASS'),
             ('tb_srp_scan', [], ['rtl/srp/rv32_srp_scan.v'], 'PASS:'),
             ('tb_srp_regs', [], ['rtl/srp/rv32_srp_scan.v', 'rtl/srp/rv32_srp_regs.v'], 'PASS:')]
    tests += [('tb_acoustic_ext', [f'-Ptb_acoustic_ext.LANES={lanes}'], ['rtl/acoustic/rv32_acoustic_ext.v'], f'ACOU_LANE_PASS lanes={lanes}')
              for lanes in [4, 8, 16]]
    for top, parameters, rtl, marker in tests:
        tag = top + ('_'+parameters[0].split('=')[1] if parameters else '')
        executable = OUT/(tag+'.vvp')
        subprocess.run([compiler, '-g2012', '-s', top, *parameters, '-o', str(executable), *rtl, f'tb/{top}.v'], cwd=ROOT, check=True)
        result = subprocess.run([runtime, '-i', str(executable)], cwd=ROOT, text=True, encoding='utf-8', errors='replace', capture_output=True)
        (OUT/(tag+'.log')).write_text(result.stdout+result.stderr, encoding='utf-8')
        assert result.returncode == 0 and marker in result.stdout and 'FAIL:' not in result.stdout, result.stdout+result.stderr
        print(tag, 'PASS', flush=True)
    print('SYSTEM_KERNELS_PASS')


if __name__ == '__main__':
    main()
