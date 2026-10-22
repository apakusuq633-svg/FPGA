# 平面 8 麦生产配置（2026-10-21）

生产硬件已改为用户确认的平面板，12 麦三面板不再采用。权威配置为 `configs/production_array.json`。旧 12/16 麦源码、测试和验收报告保留作历史参考，不能作为当前板的构建参数或验收结果。

## 正面坐标与通道

以麦克风声孔阵列中心为原点；+x 向右、+y 向上、+z 朝正面观察者，构成右手坐标系。全部声孔 z=0。

```text
             +y
              ↑
       M0           M1
       M2           M3
       M4           M5
       M6           M7       → +x
```

| 通道/麦克风 | x（mm） | y（mm） | 数据线 | FPGA 引脚 |
|---|---:|---:|---|---|
| 0 / M0 | −24.193 | +36.207 | DIN1 / pdm_din_i[0]，相位0 | T14 |
| 1 / M1 | +24.193 | +36.207 | DIN1 / pdm_din_i[0]，相位1 | T14 |
| 2 / M2 | −24.193 | +12.069 | DIN2 / pdm_din_i[1]，相位0 | Y17 |
| 3 / M3 | +24.193 | +12.069 | DIN2 / pdm_din_i[1]，相位1 | Y17 |
| 4 / M4 | −24.193 | −12.069 | DIN3 / pdm_din_i[2]，相位0 | W16 |
| 5 / M5 | +24.193 | −12.069 | DIN3 / pdm_din_i[2]，相位1 | W16 |
| 6 / M6 | −24.193 | −36.207 | DIN4 / pdm_din_i[3]，相位0 | T15 |
| 7 / M7 | +24.193 | −36.207 | DIN4 / pdm_din_i[3]，相位1 | T15 |

左右列中心距 48.386 mm，相邻排中心距 24.138 mm。坐标是用户确认的名义几何，不代表声学标定结果。沿用接收器相位约定：相位0为 LR=GND，相位1为 LR=VDD；上板通过逐麦激励核对行内顺序。

时钟 `pdm_clk_o` 接 V16；新增外部低有效 `rst_n` 接 N16，和 PS 的 FCLK_RESET0_N 相与后复位 PL。所有这些引脚均使用 LVCMOS33。用户给出的 `pdm_data`/`pdm_clk` 在本工程中的端口名分别是 `pdm_din_i`/`pdm_clk_o`。

## 数据和算法

- 8 通道、4 根双相数据线；PCM 采样率仍为 39062.5 Hz，PL 时钟仍为 40 MHz。
- 每帧 4 个 32 位字；每个字低16位为偶数通道，高16位为下一奇数通道；每 bank 512 帧、8192 字节。
- 定位为全部 28 个麦克风对、32×32 格、32 点相关环；DAS 使用 8 路真实坐标重建的转向表。
- 暂沿用前方 z=+0.3 m、x/y 各 ±0.2 m 的扫描平面。这是软件扫描设置，不是板子机械参数；平面阵列不能仅凭时差区分 z 正负镜像。
- 新固件标识为 `0xda508002`，麦电平标识为 `0x4d493038`。PS 读取 8 路电平并使用 32×32 定位结果布局，避免加载旧圆阵固件。

## 优化复用边界

| 既有优化 | 当前处理 |
|---|---|
| 8 lane SIMD-MAC 音频 FIR | 保留；lane 表示抽头分组，不随麦数缩成4 |
| FFT/VFFT、自定义 GCC/PHAT 指令 | 保留；生产固件按8通道、28对调度 |
| SRAM/BRAM 同步读、频谱缓存、相关环 | 保留；自主搬运控制器的通道、麦对、打包步长及存储深度已参数化 |
| 自主搬运与采集/计算重叠 | 生产固件已改用 `fw_planar8.c`，CPU通过自定义指令发起计算，状态机负责搬运；继续执行可信度判断、转向和原始录音协议 |
| 固定发布相位与恢复状态机 | 保留硬件机制；原12麦的延迟和吞吐指标需要重新验收 |
| 12麦 GSC 和 UDP/DMA 数据包 | 独立历史路径，不作为当前 DAS 生产入口；其12路协议不能直接套到8麦 |

当前生产集成及测量见 [降延时报告](planar8_optimization_20261021.md)。测试调度器仍独立保留；生产固件包含可信度、转向和录音暂停/恢复逻辑，不能直接用测试调度器代替。

## 构建与验证

```text
python -X utf8 scripts/build_planar8.py --compiler-prefix <工具链目录>/riscv64-unknown-elf-
python -X utf8 scripts/check_planar8.py
vivado -mode batch -source scripts/run_zynq_flow.tcl
```

默认固件目录为 `build/das8/fw`，新头文件为 `sw/acoustic_planar8_image.h`；SRP 表 28672 项，转向表 8192 项。`build_live_acoustic.sh` 已转发到新构建器。Vivado 默认目录为 `build/das8_zynq`，输出为 `build/das8`，生产工程拒绝旧 `DAS_ACTIVE_CHANNELS=12` 环境覆盖。PS 的 Live 构建入口已改用新镜像。

`check_planar8.py` 对旧 RTL 的前向声明做仅声明顺序的仿真副本适配，以兼容本机 Icarus；原运算和时序逻辑不变。它检查生产规模、双相采集、bank打包、DAS/FIR和PS电平协议。当前编译或数字仿真通过不能替代新板定位精度、引脚波形和连续实时验收；旧 bit/XSA/ELF 不能混用。

## 本次验证结果

2026-10-21：`PLANAR8_BUILD_PASS`、`PLANAR8_CHECK_PASS`、`PLANAR8_EVIDENCE_PASS` 均通过。RV32 程序 text=5220 字节、BSS=3276 字节；Cortex-A9 的 `ps_live.c` 使用现有 BSP 编译通过。五项 RTL 检查包括 `tb_srp_profiles`、`tb_planar8_overlap`、`tb_pdm_array_rx`、`tb_pdm_capture`、`tb_das_stream`，另外 PS 电平/定位协议测试通过。XDC 四线生成和 Tcl 完整性检查通过。

重叠控制器测试验证了8路输入的64字打包及8192字原始环、1664字频谱缓存尺寸，未证明自主搬运调度器的完整FFT/GCC/SRP连续运行。DAS 测试为数字仿真，不能据此声称板卡音频不丢样。本次未运行新的 Vivado 综合/布局布线，未生成可宣称验收通过的新 bit/XSA，也未执行上板验收。
