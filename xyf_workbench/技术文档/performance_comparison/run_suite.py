"""Run retained comparisons sequentially, keeping host timing clear of RTL compilation."""
from pathlib import Path
import argparse
import datetime as dt
import json
import os
import subprocess
import sys

HERE = Path(__file__).resolve().parent

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--suite', choices=['all', 'host', 'full-modules', 'pl', 'primitives', 'scalar'], default='all')
    p.add_argument('--reuse-pl', action='store_true', help='Reuse PL source mirror and built models')
    p.add_argument('--windows', type=int, default=32)
    a = p.parse_args()
    if a.windows < 1:
        p.error('--windows must be positive')
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out = HERE / 'suite_runs' / stamp
    out.mkdir(parents=True)
    env = dict(os.environ)
    env['PYTHONUTF8'] = '1'
    commands = []
    if a.suite in ('all', 'host'):
        commands.append(('host', [sys.executable, '-X', 'utf8', str(HERE / 'ps_software/run_benchmarks.py')]))
    if a.suite in ('all', 'full-modules'):
        commands.append(('full-modules', [sys.executable, '-X', 'utf8', str(HERE / 'ps_software/full_modules/run_full_modules.py')]))
    if a.suite in ('all', 'pl'):
        args = [sys.executable, '-X', 'utf8', str(HERE / 'pl_rtl/run_pl_measurements.py'), '--windows', str(a.windows)]
        if a.reuse_pl:
            args.append('--reuse')
        commands.append(('pl', args))
    if a.suite in ('all', 'primitives'):
        commands.append(('primitives', [sys.executable, '-X', 'utf8', str(HERE / 'run_primitive_checks.py')]))
    if a.suite in ('all', 'scalar'):
        commands.append(('scalar-host', [sys.executable, '-X', 'utf8', str(HERE / 'circular9_scalar/run_scalar.py'), '--all-windows', '--bench', '64']))
        args = [sys.executable, '-X', 'utf8', str(HERE / 'circular9_scalar/run_rv.py'), '--optimization', 'Os']
        if a.reuse_pl:
            args.append('--reuse-model')
        commands.append(('scalar-rv', args))
    manifest = {'scope': 'Simulation and native-host only; no board programming or A9 measurement',
                'started_utc': dt.datetime.now(dt.timezone.utc).isoformat(), 'runs': []}
    for name, command in commands:
        print('Running ' + name + '; log: ' + str(out / (name + '.log')), flush=True)
        start = dt.datetime.now(dt.timezone.utc).isoformat()
        with (out / (name + '.log')).open('w', encoding='utf-8') as log:
            proc = subprocess.run(command, cwd=HERE.parent, env=env, stdout=log, stderr=subprocess.STDOUT)
        manifest['runs'].append({'suite': name, 'command': command, 'started_utc': start,
                                 'finished_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
                                 'returncode': proc.returncode})
        manifest['passed'] = all(r['returncode'] == 0 for r in manifest['runs'])
        (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        if proc.returncode:
            raise SystemExit('FAILED ' + name + '; see retained log. Remaining suites were not run.')
    print('PASS; suite manifest: ' + str(out / 'manifest.json'))

if __name__ == '__main__':
    main()
