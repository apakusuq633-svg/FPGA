#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/accelerator_optimization
iverilog -g2012 -s tb_srp_throughput -o build/accelerator_optimization/srp_after.vvp \
  rtl/srp/rv32_srp_scan.v tb/tb_srp_throughput.v
vvp build/accelerator_optimization/srp_after.vvp > build/accelerator_optimization/srp_after.log
cat build/accelerator_optimization/srp_after.log
grep -q 'SRP_THROUGHPUT_PASS' build/accelerator_optimization/srp_after.log
python3 scripts/golden/gen_srp_vectors.py > build/accelerator_optimization/golden.log
python3 scripts/golden/gen_srp_vectors.py --pairs 4 --grid-w 16 --out-prefix srp4x256 \
  >> build/accelerator_optimization/golden.log
for top in tb_srp_scan tb_srp_regs; do
  iverilog -g2012 -s "$top" -o "build/accelerator_optimization/${top}.vvp" \
    rtl/srp/rv32_srp_scan.v rtl/srp/rv32_srp_regs.v "tb/${top}.v"
  vvp "build/accelerator_optimization/${top}.vvp" > "build/accelerator_optimization/${top}.log"
  grep -q '^PASS:' "build/accelerator_optimization/${top}.log"
  if grep -q 'FAIL:' "build/accelerator_optimization/${top}.log"; then exit 1; fi
  tail -4 "build/accelerator_optimization/${top}.log"
done
