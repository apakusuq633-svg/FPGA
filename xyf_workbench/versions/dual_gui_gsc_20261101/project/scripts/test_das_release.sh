#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
DAS_ACTIVE_CHANNELS=8 bash scripts/build_live_acoustic.sh > build/das_release_build.log 2>&1
python3 scripts/golden/gen_srp_vectors.py > build/das_srp_vectors.log
python3 scripts/golden/gen_srp_vectors.py --pairs 4 --grid-w 16 --out-prefix srp4x256 >> build/das_srp_vectors.log
gcc -O2 -I sw/fw -o build/fw_ifft_host scripts/golden/fw_ifft_host.c sw/fw/fw_fft.c sw/fw/fw_tables.c
./build/fw_ifft_host > build/fw_ifft_host.log
for tb in tb_rv32_units tb_rv32_soc tb_rv32_ps tb_vec_unit tb_vec_core tb_chan_align tb_pdm_capture tb_pdm_array_rx tb_fft_bfly tb_fft_ifft tb_acoustic_ext tb_steer tb_steer_regs tb_srp_scan tb_srp_regs tb_xspec_regs tb_loc_core; do
    iverilog -g2005 -I rtl -s "$tb" -o "build/$tb.vvp" -c scripts/filelist.f
    vvp "build/$tb.vvp" > "build/das_release_${tb}.log" 2>&1
    if ! grep -q 'PASS' "build/das_release_${tb}.log" || grep -qE 'FAIL|FATAL' "build/das_release_${tb}.log"; then
        cat "build/das_release_${tb}.log"
        exit 1
    fi
    echo "DAS_REGRESSION_PASS $tb"
done
gcc -O2 -w -DPSONLY_HOST -DFW_MEM_RELOCATE -DFW_RDCYCLE_OVERRIDE -DFW_ACCEL=0 -I sw -I sw/fw -o build/ps_only_host sw/ps_only.c sw/fw/fw_fft.c sw/fw/fw_gcc.c sw/fw/fw_srp.c sw/fw/fw_das.c sw/fw/fw_fir.c sw/fw/fw_scene.c sw/fw/fw_tables.c
python3 scripts/check_ps_only_results.py
ZYNQ_PROJ_DIR=build/das_fir_zynq python3 scripts/check_ps_apps.py
python3 scripts/check_pdm_pins.py
bash scripts/test_das_stream.sh
bash scripts/test_acoustic_acceptance.sh
bash scripts/test_das_structure.sh
echo DAS_RELEASE_SIM_PASS
