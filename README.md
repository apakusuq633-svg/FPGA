# 九麦声学定位引导故障诊断系统

基于 Zynq-7020 的九麦阵列系统。PL 内 RISC-V 声学处理器完成定位与连续音频处理，PS 双核负责历史缓存、搜索、声音分离、故障特征分析与网络服务。

## 仓库内容

本仓库只保存工程源码，不包含技术文档、实验数据和配图。

```text
xyf_workbench/zynq_-pl_-simd_-verilog/
  rtl/         RTL 源码
  sw/          固件与 PS 程序
  tb/          测试台
  constrs/     约束文件
  configs/     板级、阵列与工况配置
  scripts/     构建、仿真、检查和打包脚本
  profiles/    界面与整机配置
  pc/          PC 侧采集与数据集工具
  results/     参考结果
```

## 环境要求

| 用途 | 依赖 |
|---|---|
| RTL 仿真 | Icarus Verilog（`iverilog`、`vvp`），或可用的 WSL |
| 完整 RTL 检查 | 上述工具 + Yosys + Python 3 + GCC |
| PS 源码检查 | Python 3 + GCC |
| PL 固件构建 | RISC-V GCC（`riscv64-unknown-elf-` 或 `riscv-none-elf-`） |
| GUI 检查 | Python 3 + GCC + Node.js |
| 整机 PS 构建 | Vitis 2020.2 BSP + `arm-none-eabi-gcc` |
| 位流构建 | Vivado 2020.2 |

工具不在默认路径时，可通过参数或环境变量覆盖：

```text
CC, NODE                         主机 GCC / Node.js
RISCV_PREFIX                     RISC-V 工具链前缀
RISCV_TOOL_DIR                   RISC-V 工具链 bin 目录
FW_CC, FW_OC, FW_OD              build_fw.sh 使用的 RISC-V 工具
ARM_TOOL_DIR, ARM_BSP_DIR        PS 构建的 arm-none-eabi 与 BSP
ARM_APP_DIR, ARM_SPEC            Vitis 应用源码与 Xilinx.spec
XSCT_PATH, VIVADO_BAT            XSCT / Vivado 可执行文件
C9_PYTHON                        GUI 构建使用的 Python
C9_BSP_WORKSPACE, C9_TOOL_DIR    GUI 整机构建参数
```

## 快速检查

以下命令均在 `xyf_workbench/zynq_-pl_-simd_-verilog` 目录内执行，需要 Python 3 与 GCC：

```powershell
python scripts\check_ps_apps.py
python scripts\check_pdm_pins.py
python scripts\check_circular9_pipeline.py
python scripts\check_circular9_ps_control.py
python scripts\check_circular9_stream.py
python scripts\check_circular9_schedule.py
python scripts\check_circular9_calibration.py
python scripts\check_circular9_loader.py
python scripts\build_circular9.py --validate-only
python profiles\full_gui9\check.py     # 另需 Node.js
```

RTL 控制通路检查需要 Verilator：

```powershell
python scripts\check_circular9_control.py
```

固件构建（WSL/Linux，RISC-V GCC）：

```bash
bash scripts/build_fw.sh
# 或指定工具链前缀
python scripts/build_circular9.py --compiler-prefix /path/to/riscv64-unknown-elf-
```

`scripts\run_iverilog.ps1` 和 `scripts\verify.ps1` 是早期 Icarus 门禁。当前 RTL 的部分连线声明顺序不被 Icarus 接受，完整 RTL 验证请使用 Verilator 或 Vivado；两个脚本保留供参考。

## Vivado / Vitis 构建

```powershell
# 产品配置全流程：建工程、综合、实现、位流、报告
vivado -mode batch -notrace -source scripts\run_zynq_flow.tcl
```

输出目录可用 `ZYNQ_OUTPUT_DIR`、`ZYNQ_PROJ_DIR` 覆盖。脚本以 `SYNTH_`、`IMPL_`、`BIT_`、`REPORT_` 标记判断各阶段是否完成。

九麦 PS 平台可先用 XSCT 建立独立 BSP：

```tcl
xsct scripts/build_circular9_platform.tcl <matching.xsa> <new_workspace>
```

再按 `profiles/full_gui9/build.ps1` 的 `-Python`、`-BspWorkspace`、`-ToolDir` 参数构建 GUI 与 PS 程序。

## 说明

RTL 仿真、宿主计时和板级验证分别报告，不将不同条件下的历史记录合并为整机性能。仓库不包含 Vivado 工程、位流、BSP 和编译产物，需用上述工具链重新生成。
