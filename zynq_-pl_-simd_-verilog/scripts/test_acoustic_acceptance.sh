#!/usr/bin/env bash
# Run the production PS loader against the synthesizable AXI/RV32 RTL.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
mkdir -p build
for image in sw/fw/fw_itcm.hex sw/fw/fw_dtcm.hex sw/fw/fw_live_itcm.hex sw/fw/fw_live_dtcm.hex; do
    test -s "$image" || { echo "FAIL: missing $image; run bash scripts/build_live_acoustic.sh"; exit 1; }
done
obj="${ACOUSTIC_SIM_OBJ:-/tmp/pdm_acoustic_ps_obj}"
python3 - <<'PY'
from pathlib import Path
lines = Path('scripts/filelist.f').read_text().splitlines()
Path('build/acoustic_rtl.f').write_text('\n'.join(s for s in lines if s.startswith('rtl/')) + '\n')
PY
verilator --cc --exe --build -Wno-fatal --unroll-count 512 --unroll-stmts 100000 --top-module rv32_ps_top -GDAS_ACTIVE_CHANNELS=8 -Irtl \
    -f build/acoustic_rtl.f --Mdir "$obj" -j 4 \
    -CFLAGS "-O2 -I$root/scripts/sim_bsp" \
    "$root/scripts/acoustic_ps_sim.cpp" > build/acoustic_rtl_build.log 2>&1
"$obj/Vrv32_ps_top" > build/acoustic_rtl.log 2>&1
grep -q '^ACOUSTIC_RTL_PASS$' build/acoustic_rtl.log
grep -q '^PDM_DAS_FIR_PASS' build/acoustic_rtl.log
grep -q '^LIVE_LOCALIZATION_PASS' build/acoustic_rtl.log
grep -q '^LIVE_SEQUENCE_REJECTED error=2 snapshots=0' build/acoustic_rtl.log
# Mandatory FIR cannot pass on stale/bypassed/corrupted results.
if "$obj/Vrv32_ps_top" --corrupt-fir > build/acoustic_fir_negative.log 2>&1; then
    echo 'FAIL: corrupted FIR result was accepted'
    exit 1
fi
grep -q '^ACOUSTIC_RTL_FAIL$' build/acoustic_fir_negative.log
grep -q '\[FAIL\] acoustic result at 0x000038c8' build/acoustic_fir_negative.log
echo 'ACOUSTIC_ACCEPTANCE_PASS: production PS loader + real AXI/RV32 RTL + FIR negative control'
