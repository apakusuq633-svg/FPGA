# 12麦自主搬运、核指令计算及BRAM实现：2026-10-15

此报告对应保留的原已验收构建。后续风险验收发现并修复HALT/WB、故障隔离、组计数回卷及退休握手问题；当前代码、非周期1024窗和新40MHz实现见[连续运行安全报告](localizer12_realtime_safety_report.md)。不得用本报告旧位流替代新RTL的实现证明。

当前结论：**TEST_GEOMETRY_ONLY 整机RTL严格验收PASS，40 MHz产品配置完整实现PASS；未下载板卡，实际几何定位精度未验收。** 用户“进行修改”已授权原A-RTL-118选项3。进入时HEAD为`ec72368`，本报告对应未提交工作区；精确RTL/ROM哈希见实现及仿真manifest。

## 实际数据通路与自研核作用

`pdm_aligned/pdm_valid_aligned` → 原始2048点环 → 1024点统计/DC/缩放/Hann → 12次FFT → 66对共轭互谱/PHAT → 66次IFFT → 32点相关环 → 1024格SRP → 最佳格点。

`rv32_overlap_localizer`的`CPU_SCHEDULED=1`状态机负责地址、数据、补零、共字打包、同步RAM预取和所有权切换。统计/DC/缩放/Hann也由该硬件完成。FFT/GCC/SRP复用核及SoC现有算子，没有复制一套独立GCC引擎。RV32固件根据请求编号和类型，实际执行原有FFT RUN、IFFT RUN、VSUB共轭互谱、VPHAT及SRP自定义指令；完成信号必须与核提交握手一致，HALT或访存停顿不会提前切换状态。

256窗退休监测得到正FFT3072、IFFT16896、互谱16896、PHAT16896、SRP256次。数据搬运已脱离标量lw/sw循环，自研核仍负责主要计算指令的发射、顺序和完成控制。八路SIMD音频FIR保持原实现。

SRP LUT、相关环和分数RAM使用同步BRAM流水；相邻lag读取保留有符号插值、环绕及逐对清空流水。FFT/IFFT输入及GCC输入提前产生下一地址，在算子接受数据时可连续每拍传输一个32位字，遇反压保持当前地址。小GRID也须排空流水，避免分数RAM读写相关。

## 接口与启用边界

新增CPU MMIO页`0xD000`，偏移单位为字节；旧接口保留。

| 偏移 | 含义 |
|---|---|
| 0x00 | CTRL；bit31与bit0同时置位才开启显式测试模式 |
| 0x04 | 请求种类及busy |
| 0x08 | 单调请求编号 |
| 0x0c | 窗口编号 |
| 0x10 | 窗口FIRST样点编号 |
| 0x14 | 最后样点至结果发布时间 |
| 0x18 / 0x1c | 原始丢样 / 跳窗计数 |
| 0x20 / 0x24 | 最佳格点 / 分数 |
| 0x28 | 接口标记0x4c4f4301 |
| 0x2c | 最后样点至计算完成时间 |

复位默认关闭；测试固件`sw/fw/fw_localizer12.c`显式启用，不更新实际DAS转向。实际XYZ、麦克风物理映射和坐标轴尚未提供，`production_array.json`仍禁用几何。交付ELF是**256窗后停止的验收固件**，不是已验证实际角度的连续生产固件。`LOCALIZER_PCM_TEST`仅用于Verilator测试输入，产品综合没有该宏；XSim使用既有PCM注入方式，PDM/CIC另有独立回归。

## 当前实测

输入40 MHz，每1024拍一组12路PCM；1024点窗、512点Hop、12次FFT、66对完整GCC/IFFT、1024格完整SRP，没有减少通道、对数或格点。

| 项目 | 结果 |
|---|---:|
| 连续完整窗口 | 256，FIRST从0至130560，步长512 |
| 最大计算耗时 | 323568拍 / 8.0892 ms |
| 最后样点至结果发布 | 每窗393217拍 / 9.830425 ms |
| 255次结果间隔 | 全部524288拍 / 13.1072 ms |
| 原始逐点比较 | 3145728个通道样点一致 |
| 所有FFT/PHAT/相关环/SRP分数 | 与参考逐位一致 |
| 音频输入/输出/丢样 | 131968 / 131968 / 0 |
| 音频最大处理时间 | 101拍 |
| raw_drop / window_drop | 0 / 0 |
| 完整实现WNS / WHS | +0.622 / +0.030 ns，TNS/THS均0 |
| LUT / FF / BRAM / DSP | 29752 / 16824 / 111.5 / 132 |
| LUT as Memory | 2884 / 17400 |

计算完成后等待固定发布相位，防止CPU轮询抖动产生524289或524296拍的结果间隔；等待期间保留当前新结果，不重复发布旧窗口。采集仍持续进行。单独计算完成时间与发布延迟分别记录，不以吞吐替代逐窗延迟。

各阶段是状态机驻留时间，含核发射握手和等待，不等于裸算子周期；详细均值/最大值在`build/localizer12/final256/strict_summary.json`的`stage_statistics`。最大值：准备73741、FFT输入6156/计算11493/输出6156、GCC输入27588/互谱6068/PHAT13068/输出13728、IFFT输入33924/计算59202、相关环取回2244、SRP计算68145/分数读取2048拍。

与本轮中间版同向量256窗相比，预取连续传输使计算最大值389012→323568拍，减少65444拍（16.82%）；发布491521→393217拍。旧独立模块29573 LUT/17468 LUTRAM的布局失败不是相同范围的整机资源基线，不能从其总LUT推算整机释放量。当前大RAM映射成功、LUTRAM降至可实现范围，但整机BRAM占79.64%。

## BRAM物理布局与证据

`scripts/apply_localizer_floorplan.tcl`在opt后建立软Pblock：SRP在X0列三个时钟区，数据状态机及复用FFT/GCC在X1列三个时钟区。保留工具越界优化自由，未锁死单个SLICE。生成层级名使用`g_localizer*`匹配，确保真实`g_localizer.u_transfer`被纳入。同步RAM输出寄存、地址预取及分级运算共同缩短组合路径，不能仅靠`ram_style`或Pblock保证最低延时。

真实位置：`build/localizer12_final/implementation/localizer_bram_locations.csv`；穿过BRAM路径：`localizer_bram_paths.rpt`；全局关键路径：`localizer_critical_paths.rpt`；层级资源：`localizer_hierarchy.rpt`。最终时序以`timing_zynq.rpt`为准。无区域约束对照单独保存在`build/localizer12_final/unconstrained`，不得覆盖所选位流。

同一`synth_1`综合网表、同一opt/place/phys_opt/route指令下，完整无Pblock布线对照也已完成：

| 物理结果 | 无区域约束 | 当前软Pblock |
|---|---:|---:|
| 全局WNS | +0.596ns | +0.622ns |
| 全局WHS | +0.039ns | +0.030ns |
| 所报最差BRAM输出路径余量 | +0.862ns | +1.116ns |
| 该路径数据延时 | 23.652ns | 23.376ns |
| 该路径布线延时 | 10.340ns | 10.138ns |
| LUT / FF | 29759 / 16821 | 29752 / 16824 |

两版均满足40MHz setup/hold，BRAM/DSP相同；当前软Pblock提高了全局和所报最差BRAM输出setup余量，故保留当前位流。两版最差路径的FFT lane不同，表中是各自最差路径比较，不是同一根网线的延时对照，也不证明全局最优布局。复现脚本`compare_localizer_floorplan.tcl`，日志末尾`LOCALIZER_UNCONSTRAINED_COMPLETE wns=0.596 whs=0.039`。两个区域仍允许工具越界优化。

## 复现与交付

WSL运行：

```sh
python3 scripts/check_localizer12.py --windows 256 --tag final256
python3 scripts/summarize_localizer12.py build/localizer12/final256 --implementation build/localizer12_final/implementation
python3 scripts/check_rv32_mem_regression.py
python3 scripts/check_rv32_mem_perf.py --output build/localizer12_final/mem
python3 scripts/check_rv32_mem_perf.py --mmio-unrolled --output build/localizer12_final/mmio
python3 scripts/test_overlap50_strict.py
python3 scripts/package_localizer12.py
```

Native PowerShell XSim入口为`check_live16_xsim.ps1 -Transfer`，本次`transfer_final4_drained`四窗原生40MHz PASS，音频2944/2944、drop0。9项模块/CPU/PS回归、76项访存及8项MMIO微基准、17项严格统计反例测试均PASS。5000拍核HALT仍完整四窗通过；样点序号断裂和700000拍HALT分别触发预期CAPTURE_LOSS，不静默跳窗。

产品实现脚本`scripts/run_zynq_flow.tcl`使用环境变量`DAS_ACTIVE_CHANNELS=12`、`LOCALIZER_FLOORPLAN=1`，`ZYNQ_PROJ_DIR`及`ZYNQ_OUTPUT_DIR`分别指向`build/localizer12_final/zynq`和`implementation`的绝对路径，日志含`FLOW_PASS`。验证脚本将当前RTL/ROM、256窗仿真manifest与实现manifest逐一比较，哈希相同才接受时序。

交付清单见`build/localizer12_final/release_manifest.json`，包括最终bit、含bit的XSA、routed DCP及与256窗测试匹配的ELF/hex哈希。构建和仿真没有下载板卡或写Flash；周期性2048点测试向量验证了256窗覆盖、环绕和调度，不能替代任意声场/实际几何/物理板卡验收。
