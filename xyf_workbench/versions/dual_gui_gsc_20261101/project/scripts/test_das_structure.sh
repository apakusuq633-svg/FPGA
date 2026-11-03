#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
python3 - <<'PY'
from pathlib import Path
rtl = [s.strip() for s in Path('scripts/filelist.f').read_text().splitlines() if s.strip().startswith('rtl/')]
actual = {p.as_posix() for p in Path('rtl').rglob('*.v')}
if set(rtl) != actual or len(rtl) != len(set(rtl)):
    raise SystemExit(f'MANIFEST_FAIL missing={actual-set(rtl)} stale={set(rtl)-actual}')
for path in Path('scripts').glob('*.ps1'):
    path.read_text(encoding='ascii')
read = 'read_verilog -I rtl ' + ' '.join(rtl)
commands = []
for top in ('rv32_soc', 'rv32_ps_top'):
    commands += [read, f'hierarchy -top {top}', 'proc', 'opt',
                 'select -assert-none t:$dlatch t:$adlatch t:$dlatchsr t:$sr', 'design -reset']
Path('build/das_structure.ys').write_text('\n'.join(commands)+'\n')
print('DAS_MANIFEST_ASCII_PASS')
PY
yosys build/das_structure.ys > build/das_structure.log 2>&1
echo DAS_STRUCTURE_PASS
