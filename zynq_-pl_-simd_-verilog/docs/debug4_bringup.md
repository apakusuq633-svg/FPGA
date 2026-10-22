# 四麦调试配置

用户补充实测尺寸后，阵列修正为平行四边形，取代早先估算的 50×35 mm 矩形。原图坐标/cm：M0=(0,0)、M1=(3.2,0)、M2=(4.442,4.636)、M3=(1.242,4.636)；照片中 M0 右上、M1 右下、M2 左下、M3 左上。原图第一坐标轴指向照片下方，第二轴指向左方。原图 FPGA 引脚不沿用，用户确认现有 J3 接线保持不变。
坐标以阵列中心为原点，向右为 x 正方向，向上为 y 正方向。

| 通道 | 用户确认位置（照片视角） | 坐标/mm | FPGA 管脚 | 接口 |
| --- | --- | --- | --- | --- |
| DIN0 / M0 | 右上 | (+23.18,+22.21) | T14 | J3.34 |
| DIN1 / M3 | 左上 | (-23.18,+9.79) | Y17 | J3.32 |
| DIN2 / M2 | 左下 | (-23.18,-22.21) | T15 | J3.33 |
| DIN3 / M1 | 右下 | (+23.18,-9.79) | W16 | J3.35 |

PDM CLK 使用 V16/J3.36。各麦克风独立数据线，前端要求 L/R=GND。
DIN0～3 使用 J3.34/32/33/35 顺序，用户于 2026-10-12 确认其位置分别为右上、左上、左下、右下。坐标与定位/转向延迟表按此对应更新。尺寸为近似值，定位准确性仍需实测验收。
电源使用 J3.38（+3.3V），地使用 J3.37。

默认八麦配置保留。四麦配置保留原 XDC 的八路端口，使用前四路，后四路不参与 DAS 求和；平均除以 4。
采集/缓存和转向模块仍按 8 路硬件容量实例化，四麦并非裁剪后的纯四路设计。定位固件仅用前四路，麦克风对为 (0,1)、(0,2)、(0,3)、(1,3)，未使用未接麦克风的后四路。
寄存器 0x3c0 可读有效通道数；四麦 PS 固件启动时要求值为 4，防止误配八麦位流。
SRP 使用四对 (0,1)、(0,2)、(0,3)、(1,3)，几何和自动转向表同步生成。
扫描仍为 16×16，平面 z=300 mm，横纵范围 ±200 mm；未根据照片推断声源距离。

构建：`python scripts/build_debug4.py`；PS 使用 `scripts/build_ui_pipeline.ps1 -Live -MatchingPlWindow -ActiveChannels 4`。
Vivado 使用环境变量 `DAS_ACTIVE_CHANNELS=4`、`ZYNQ_PROJ_DIR=build/das4_zynq`、`ZYNQ_OUTPUT_DIR=build/das4` 执行 `scripts/run_zynq_flow.tcl`（路径应设为绝对路径）。
打包检查：`python scripts/package_ui_live.py --debug4`。

当前产物：

- 位流：`build/das4_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit`
- 初始化：`build/das4_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl`
- PS：`build/ui_pipeline_live4/ui.elf`
- XSA：`build/das4/das_fir.xsa`
- 清单：`build/das4/ui_live_release_manifest.json`

接线版实现时序 WNS +0.553 ns、WHS +0.031 ns，失效端点为零。
四麦约束由 `scripts/configure_debug4_pins.tcl` 从默认 XDC 生成完整配置；不能直接在另一份 XDC 中置换已经占用的管脚。
本次接线修正复用完成的综合，执行 `scripts/rebuild_debug4_pins.tcl`，出位流前检查通道管脚，打包时再次核对 IO 报告。

2026-10-12 已下载本版位流及 PS ELF，COM3/115200 启动正常，PHY 协商到 1000 Mbps，网页地址为 http://192.168.2.10/。
连续 30 秒观测共 57 次 HTTP 请求，诊断帧增加 29，512 点块增加 2281；单段处理最大 163 ms，频谱/包络组合有 30 组不同数据。
所有观测均为真实输入 `input_mode=2`、`synthetic=0`、`input_channels=4`；PL/PS 丢样和不连续计数均为零。
JTAG 只读检查：trap=0，mailbox=0xDA500001，FIFO 丢样=0，有效通道寄存器=4，PDM frozen=0xF0（前四路有位流活动，后四路未连接）。
这证明真实输入的数据传输和处理通路持续运行；尚未做受控声源测试、定位准确性或波束增强收益验收。

证据：`build/das4/board_uart_live4_2.log`、`build/das4/live_board_monitor_1.json`。
重复通路检查可使用 `scripts/monitor_live4_board.ps1`；只读寄存器检查使用 `scripts/probe_live4_status.tcl`。
打包清单的 `board_tested=false` 表示打包工具自身不执行上板验收，上述日志记录本次独立实测。
FIFO 不提供音频与定位的时刻关联，网页继续明确显示此限制。
