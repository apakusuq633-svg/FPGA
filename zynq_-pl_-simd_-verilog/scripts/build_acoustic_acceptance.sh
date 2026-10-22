#!/usr/bin/env bash
# Build the FFT/DAS/FIR acceptance image and its PS download header.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
for model in fw_fft_model fw_gcc_model fw_srp_model fw_das_model fw_fir_model gen_steer_vectors; do
    python3 "scripts/golden/${model}.py"
done
# Keep the repository toolchain default; newer GCC can set FW_ARCH=rv32im_zicsr.
bash scripts/build_fw.sh
python3 scripts/gen_acoustic_image.py
