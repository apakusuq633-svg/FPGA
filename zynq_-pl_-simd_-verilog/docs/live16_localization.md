# 16 麦定位与自动转向配置

2026-10-13：16麦默认选择本生产配置：120对、32×32（1024格）；固定方向历史诊断配置须显式LIVE16_LOCALIZATION=0 / -FixedDas16。新增[定位质量与确认](localization_stability.md)，修正采集同步读；FFT缓存8208字、全部1024空间评分、参考模型、PS/GUI回归及40MHz位流通过。新固件完整8帧/88919个连续DAS/FIR样点逐位通过、全部16路延迟收敛、丢样0，配套清单通过。真实16麦阵列尚未到位，当前四麦板未下载本配置。下文旧7帧成绩明确属于修改前历史版本。

## 几何与输入

- 两麦共用 DIN，共 8 根 DIN、16 通道。CH2k 为 DINk 的 GND 相，CH2k+1 为 VDD 相。
- 暂按最终方案的半径 50 mm 圆阵；CH0 从 +X 开始，逐通道逆时针 22.5°。实物槽位与 DIN/LR 的映射仍须确认。
- 扫描平面 Z=300 mm，X/Y 各 −200..200 mm，32×32 共 1024 格；声速 343 m/s。
- Fs=39062.5 Hz，PDM CLK=2.5 MHz。标准 8 DIN 管脚沿用固定方向配置，不使用四麦的调试重排。
- 几何来源与 LUT 由 `scripts/build_live16.py` 统一生成；配置见 `configs/live16_geometry.json`。

构建入口还从固件旋转因子表生成或校验 `build/fft_tw.hex` 的512个字。已有ROM不匹配时停止，避免仿真、固件和位流使用不同FFT表；已有且一致时不改写文件时间。

## 计算与存储

每次定位采集两个连续 512 点快照。16 路各计算一次 1024 点实数 FFT，缓存 513 个复数 bin；120 个麦对复用这些频谱，执行 PHAT 和 IFFT。连续 DAS/FIR 音频独立运行，定位快照计算不会阻塞音频。

原来的 16 KB DTCM、邮箱和全部 MMIO 地址保持；只有 `LIVE16_LOCALIZATION=1` 才增加数据侧 0x10000..0x1FFFF 的独立 64 KB BRAM 缓存，不允许该窗口同时写入低地址 DTCM。

| 数据 | 地址／大小 |
|---|---|
| 16 路 FFT 缓存 | 0x10000，16×513×4=32832 B |
| 单通道 PCM 工作区 | 0x19000，2048 B |
| IFFT 相关工作区 | 0x19800，2048 B |
| 主瓣外质量判断评分缓存 | 0x1A000，1024×4=4096 B |
| 状态、统计与定位结果 | 原 DTCM 0x2800..0x29FF |
| 栈顶 | 原 DTCM 0x3FF0 |
| SRP LUT | 120×1024×9 bit，独立扫描器 BRAM |
| SRP 相关环 | 120×32×16 bit，独立扫描器 BRAM |

短相关环的 0..15 对应原相关序列 0..15，16..31 对应原序列 1008..1023（延迟 −16..−1）。不能直接截取原序列前 32 点。100 mm 最大基线的物理延迟界限约 11.39 样点；本扫描平面 LUT 的最大绝对延迟为 7.781992 样点。插值始终读取本麦对的环内相邻点。

SRP ADDR 扩为 IDX[16:0]、SEL[18:17]：LUT=0，R=0x20000，P=0x40000；固定配置仍使用旧的 15 位格式。定位配置的 SRP VERSION 高半字=0x0012，PS 和固件都检查此值，防止错误位流配上定位固件。

转向 LUT 使用 `(distance[0]−distance[m])*Fs/c`；硬件减去最小值后得到 `max(arrival)−arrival[m]` 的补偿延迟。SRP 麦对延迟则使用 `arrival[a]−arrival[b]`，两种 LUT 的符号不能混用。

定位固件先进行质量判断、初次2帧/远跳3帧确认与约26mm抖动保持，仅将有效确认方向交给转向器。转向器保留3/3/64策略：连续3次有效提交进入锁定，离开区域保留3次，渐变步长为当前最大落差的1/4。首次候选不提交，因此硬件锁定比旧固件晚一轮。全部16通道参与几何、变化检测和最大落差计算；32格轴坐标使用5位。

## PS 结果接口

RESULT 是 0x2800 开始的 32 位字数组。

| 字号 | 含义 |
|---|---|
| 0 | 0xDA516002，定位配置标识（固定配置为 0xDA516001） |
| 1、2、3 | 定位帧号、确认/保持的网格编号、错误码 |
| 4、5 | 计算周期数、含快照等待的总周期数 |
| 6、7 | 第一与第二大空间评分 |
| 8..87 | 16 路原始快照统计，每路 sum/energy_lo/energy_hi/peak/clipped |
| 88、89 | 麦电平 seqlock、magic=0x4D493136 |
| 90、91 | 定位 seqlock、定位有效标识 |
| 92..94 | 网格边长 32、快照首样本编号、转向状态 |
| 96..103 | LQT1 magic、拒绝原因、分离度‰、原始候选格、主瓣外最高分、接受数、拒绝数、峰值/麦对数 |

定位写入期间 sequence 为奇数，完成为偶数。PS 只发布前后 sequence 一致的结果；序号 90 与电平序号 88 相互独立，不能复用四麦的 30/31（该位置在16麦统计区内）。

GUI支持16路电平、32×32最新定位和短期轨迹；区分网页5Hz轮询与定位计算耗时，显示拒绝原因、原始候选/确认位置、峰值分离度及计数。分离度不是定位正确率。LQT1元数据在定位seqlock内发布，旧固件无magic时保留best>second兼容规则。四麦元数据使用RESULT字1080..1087（0x38E0保留区），不能放入0x2880的FFT工作区。音频FIFO仍不携带实际转向版本及硬件首样本时间戳，因此最新定位与诊断音频段明确标为独立结果。

## 复现

```powershell
python scripts/build_live16.py
python scripts/check_live16_model.py
python scripts/check_live16_localization.py --skip-soc
python scripts/check_location_robustness.py
python scripts/check_ps_apps.py
node scripts/check_ui_page.js
powershell -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -SpectraOnly
powershell -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Natural
powershell -ExecutionPolicy Bypass -File scripts/build_ui_pipeline.ps1 -Live -MatchingPlWindow -ActiveChannels 16

$env:DAS_ACTIVE_CHANNELS='16'
Remove-Item Env:LIVE16_LOCALIZATION -ErrorAction SilentlyContinue # 验证16麦默认开启定位
$env:ZYNQ_PROJ_DIR="$PWD/build/das16_loc_zynq"
$env:ZYNQ_OUTPUT_DIR="$PWD/build/das16_loc"
New-Item -ItemType Directory -Force build/xilinx_temp | Out-Null
$env:TEMP="$PWD/build/xilinx_temp"
$env:TMP=$env:TEMP
& 'E:\Vivado2020.2\Vivado\2020.2\bin\vivado.bat' -mode batch -notrace -source scripts/run_zynq_flow.tcl *> build/das16_loc_console.log
python scripts/package_live16.py
```

位流使用 `DAS_ACTIVE_CHANNELS=16`、`LIVE16_LOCALIZATION=1`，独立工程 `build/das16_loc_zynq`，输出 `build/das16_loc`。固定方向产物在 `build/das16`，四麦产物在 `build/das4`。

Vivado XSim 交叉验证入口为 `scripts/check_live16_xsim.ps1`；该脚本只调整临时副本中的旧式前置声明和 ROM 路径，不修改生产 RTL。Icarus 完整 SoC 仿真耗时较长，扫描/转向模块可用 `check_live16_localization.py --skip-soc` 单独复核。

匹配产物：

| 内容 | 路径 |
|---|---|
| PL 位流 | `build/das16_loc_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit` |
| 硬件导出 | `build/das16_loc/das_fir.xsa` |
| PS 程序，内含 RV32 镜像与 LUT | `build/ui_pipeline_live16_loc/ui.elf` |
| RV32 程序 | `build/das16_loc/fw/fw_live16.elf` |
| PS 初始化 | `build/das16_loc_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl` |
| 之前暂停时的阶段记录（历史） | `build/das16_loc/live16_partial_manifest.json` |
| 持续收敛验收通过后的配套清单 | `build/das16_loc/live16_manifest.json` |

打包检查包含位流与 XSA 内嵌位流一致、实际 BD 参数、8 根 DIN 管脚、ROM/固件/LUT 哈希、产物新鲜度与仿真通过标识。尚未执行 16 麦上板下载；硬件到位后先确认槽位与 DIN/LR 对应，再按实物重生几何 LUT 和 PS 程序。

## 本次验收记录

16路采集/FFT缓存8208字全部逐位匹配，首个候选格773须等待下一帧确认（valid=0、reason=16）；完整RV32/RTL首帧全部1024评分与参考一致。计算10300071拍、总11347700拍；40MHz折算257.502ms/283.693ms。持续使用生产固件与3/3/64转向策略，没有PS重复提交目标，全部8帧位于预期格773，第二帧有效、第四帧自动锁定。

| 帧 | 计算拍数 | 总拍数 | 方向锁定 |
|---|---:|---:|---|
| 1 | 10300071 | 11347700 | 否（首次候选待确认） |
| 2 | 10302342 | 11350206 | 否 |
| 3 | 10299830 | 11348477 | 否 |
| 4 | 10299332 | 11347419 | 是 |
| 5 | 10302550 | 11351133 | 是 |
| 6 | 10300761 | 11349200 | 是 |
| 7 | 10301012 | 11349195 | 是 |
| 8 | 10299956 | 11347883 | 是 |

完成指纹：`LIVE16_NATURAL_PASS frames=8 samples=88919 steered_samples=44589 settled_samples=256 drops=0`。全部88919个连续DAS/FIR样点逐位一致，最终16路延迟等于独立几何参考，收敛后额外256个连续稳定样点通过。日志`build/das16_loc/xsim_natural/simulation.log`，XSim墙钟运行43分31秒；TB时钟100MHz，用40MHz折算周期，不能当成实阵列采样/定位频率测量。

第2～8帧总周期均值11349073.286拍，40MHz折算283.726832ms、3.524517Hz；旧固件约3.630891Hz→新固件约3.524517Hz。质量处理和同步读取增加耗时，20～50Hz目标仍未实现。初次/远跳的确认又会增加方向变化延迟，见测试方法中的稳定性/响应速度取舍。

默认16麦位流重建通过，WNS+0.164ns、WHS+0.022ns，LUT34139/DSP191/BRAM93.5；与之前显式定位位流相同。软件防漂移150个测试及PS/GUI回归通过。`package_live16.py`通过，生成`build/das16_loc/live16_manifest.json`，包含本次日志、周期/折算速率、位流/XSA一致、固件与LUT、质量测试结果及源码哈希，并拒绝早于当前源文件/场景的仿真。下载路径`run_board.tcl -check`通过，没有连接或复位硬件。旧配套清单已另存为pre_quality历史文件。

## 防漂移修改前的历史验收

软件参考模型：两个无噪声、单声源、预设网格场景（773 和 250）均选中预设格。它们仅用于验证合成链路，不代表真实定位误差为零。

RTL 扫描：两个场景的全部 1024 个评分逐位匹配参考模型；完整扫描 120×1024 个组合需要 614400 拍（40 MHz 下解析为 15.36 ms）。转向覆盖 16 路、编号超过 255 的网格，以及仅 CH15 改变的检测与步长计算。

Icarus 完整 SoC：执行真实 RV32 定位固件，输入为注入通道对齐输出处的 16 路合成 PCM（本测试不覆盖物理 PDM）。首个结果为网格773、有效标识1，全部1024评分匹配参考。计算9968351拍，总耗时11015972拍；按40MHz解析为249.209ms和275.399ms，首帧折算约3.63Hz，尚未满足README的20～50Hz目标。这不是实际阵列实测帧率，也不是稳态帧率测量。XSim独立交叉复核得到相同首帧周期数与音频结果，日志 `build/das16_loc/xsim/simulation.log`。

连续 DAS/FIR 共核检查11014样点，丢样0；首个固件定位之后，测试暂停CPU并通过PS转向控制接口重复提交该目标，核对全部16路几何补偿和256个增强样点。生产迟滞/渐变策略另由扫描/转向TB验证；本SoC测试没有测量生产固件连续多帧进入锁定的耗时。原始记录为 `build/das16_loc/soc.log`。

2026-10-13 持续生产固件的XSim复核使用 `check_live16_xsim.ps1 -Natural`，不通过PS提交目标或改写迟滞参数；首帧核对后恢复CPU，保留生产3/3/64策略持续运行。之前第五轮暂停记录保存在 `build/das16_loc/xsim_natural/simulation_paused_frame5.log`，本次从复位重新完整运行。

| 帧 | 计算拍数 | 总拍数 | 方向锁定 |
|---|---:|---:|---|
| 1 | 9968351 | 11015972 | 否 |
| 2 | 9968539 | 11016351 | 否 |
| 3 | 9968651 | 11017278 | 是 |
| 4 | 9968810 | 11017333 | 是 |
| 5 | 9968386 | 11016741 | 是 |
| 6 | 9968556 | 11016319 | 是 |
| 7 | 9966844 | 11015455 | 是 |

各轮目标均为773，第三轮自行锁定，最终全部16路补偿等于独立几何参考。连续DAS/FIR共核对75564个样点，其中43288点使用转向状态；延迟收敛后再连续核对256个稳定增强样点。末尾读取丢样寄存器为0，完成指纹：`LIVE16_NATURAL_PASS frames=7 samples=75564 steered_samples=43288 settled_samples=256 drops=0`。渐变期间音频参考使用实际当前补偿，最终收敛值另外与独立几何参考比较。

第2～7轮总周期均值为11016579.500拍，按生产40MHz折算275.414488ms、3.630891Hz。这是合成PCM条件下的仿真周期折算，不能代替真实阵列实测；20～50Hz目标仍未满足。

`package_live16.py` 已通过，最终清单 `build/das16_loc/live16_manifest.json` 包含匹配产物、LUT、PS源码、ROM和仿真日志SHA256。旧阶段清单保留暂停时的事实，不作为当前完成状态。

40 MHz 布局布线及位流已完成：WNS +0.164 ns、WHS +0.022 ns，setup/hold/pulse-width失效端点均0；LUT34139/53200（64.17%）、DSP191/220（86.82%）、BRAM93.5/140（66.79%）。真实阵列采集、定位误差与增强收益：未验收。音频与定位精确关联、定位刷新率优化仍是后续事项。
