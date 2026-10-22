#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
python3 scripts/golden/fw_fir_model.py
python3 - <<'PY'
from pathlib import Path
Path('build/das_rtl.f').write_text('\n'.join(s for s in Path('scripts/filelist.f').read_text().splitlines() if s.startswith('rtl/')) + '\n')
PY
iverilog -g2012 -I rtl -s tb_das_stream -o build/tb_das_stream.vvp -c build/das_rtl.f tb/tb_das_stream.v
vvp build/tb_das_stream.vvp | tee build/das_stream.log
grep -q '^DAS_STREAM_PASS' build/das_stream.log
