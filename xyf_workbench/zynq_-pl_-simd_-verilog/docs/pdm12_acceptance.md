# PDM_12 V1.0 执行记录

依据：`docs/PDM_12_taskbook.md`，逐字复制用户Downloads中的任务书。
开始版本为10f6c3a，后续测量使用该基线上的源码修改；构建清单逐文件SHA256
标明实际测量版本。时间2026-10-14，所有周期为RV32/RTL仿真，40MHz时间为折算。
本文件初始基线没有板卡下载；后续已完成访存微基准和TEST几何完整算法实板测量，
详见[访存审计](perf_rv32_mem_audit.md)与[性能报告](perf_rv32_bottlenecks.md)。没有真实声源定位验收。仅确认三个相邻、两两垂直面，每面4麦。
面内排列、XYZ、物理通道映射、方向基准保持未知。

## P0-1：已验证

命令：`wsl python3 scripts/check_cycle_profile.py`。检测到WSL可调用PowerShell时
默认采用已有Vivado XSim入口，亦可显式`--simulator iverilog`。
归档：`build/pdm12_baseline/{summary.json,build_manifest.json,simulation.log}`。
两轮快照，连续音频4136点，丢样0，无退休异常；背靠背rdcycle基线2拍。

| 数值 | 怎么量 | 口径 |
|---|---|---|
| 五段1067607拍 / 26.690175ms | 每路rdcycle差值，12路相加，共字采集只计一次 | capture/统计、prepare/Hann、12 FFT输入/运算/输出 |
| RESULT(4)=1069666拍 / 26.74165ms | 计算入口至结果发布 | 含五段和2059拍外围开销 |
| RESULT(5)=2118170拍 / 52.95425ms | 快照启动至本轮完成 | 含采集等待；比RESULT(4)多1048504拍 |
| GCC/IFFT=0，SRP=0，转向=0 | 显式模式与固件分支核对 | 不能称为完整定位周期 |

五段插桩影响寄存器分配。细粒度诊断另设FW_DETAIL_PROFILE，不能把其周期当
普通插桩基线。连续音频与定位快照是不同实时任务，不以26.2144ms窗口推断音频失效。

## P0-2：接口已验证，真实几何待定

统一字段mic_xyz[12][3]、channel_to_mic[12]、单位m和coordinate_frame均已定义；
坐标、排列、各面的mic_ids及轴方向都为null。faces仅记录三个面各4麦。
`scripts/pdm12_geometry.py`自动枚举66对，缺失坐标/映射时geometry_enabled=0。
生产构建校验门控；独立TEST_GEOMETRY只验证接口，不能产生正式方向。
命令`wsl python3 scripts/check_pdm12_geometry.py`通过66对唯一性、缺失资料门控、
测试几何隔离、越界滞后与插值反证。

## P0-3：四帧数值通过，完整SRP专项测试已补充

独立FW_NUMERIC66/FW_GCC_AUDIT仅做几何无关的数学运算，不输出SRP方向，
不提交转向。12路正FFT缓存，然后66对生产SIMD互谱/PHAT和32点相关环。
每对额外执行完整1024点IFFT以逐位核对，与算法工作量分别计时。
Python固定点FFT、互谱、LUT PHAT、完整IFFT生成参考；宿主标量C逐位对照通过。
还记录LUT近似与精确除法基线的相关序列差异，不混淆算法近似误差与RTL错误。
测试信号为4帧：延迟宽带、弱源+DC/常值通道、独立满幅PCM、静音。
TEST_SIGNAL_DELAYS不是物理麦坐标，不绑定实物面或通道。
基准命令：

```powershell
wsl python3 scripts/gen_pdm12_numeric.py
wsl python3 scripts/build_live12.py --profile --numeric66
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Twelve -CycleProfile -Numeric66 -SnapshotFrames 4 -RunTag numeric_baseline
```

NUMERIC66_FRAME记录66对环路径与额外全序列验证；GCC_STAGES记录谱输入、
互谱、PHAT、取回/填零和IFFT输入/运算/环输出，不能重复叠加嵌套阶段。
scratch缓存、帧、相关序列、第二路帧和PHAT审计区彼此隔离；边界哨兵检查。
完整相关验证和PHAT审计复制属于测试开销，不代表正式定位计算。

## P0-4：软件保护已建立，真实覆盖未验证

固件实际回读0..15及1008..1023，对应0..15、-16..-1，按这个顺序存放。
SRP使用模32索引。validate_query拒绝不在支持范围的整数索引及插值邻点。
几何检查计算ceil(distance*Fs/c)，保守留一整数样点邻域；真实XYZ到位前
不判定32点覆盖阵列，不生成正式延时表。

## P1-1 / P1-2：诊断中

capture细粒度记录MMIO、拆包、存数组和原始统计；prepare记录DC扫描、去DC峰值、
定标选择、定标写回和Hann。objdump和函数分类随ELF自动保存；不再引用旧PC范围
冒充当前函数计时。EX residency包含阻塞，与退休指令数不同。
候选INDEX增量整理没有周期收益，未推广。融合预处理已完成260场景宿主逐点验证
及四帧264对RTL数值测试；prepare平均597689.5→486914.25拍，节省110775.25拍。
融合预处理复用同帧capture sum，合并定标和Hann，保留原int16截断边界。
候选在显式构建宏下启用；没有实施RAM B口或新的VFFT块搬运指令。

## P1-3 / P2

多帧逐帧记录五段、RESULT(4/5)、FIRST间隔、READY/SEQ/ACKSEQ、音频最长处理周期、
采集和音频丢弃。当前协议用CAP CTRL重启释放冻结快照，不能把其误写成ACKSEQ释放。
正式方向更新数保持0。无几何完整数值链四帧264对通过；另以隔离TEST_GEOMETRY
补充66对/1024格点SRP四帧逐格数值验收与实板性能，详见访存专项报告。
真实SRP/转向、三维角度准确性、板级同步及长期音频结果均须待坐标和实板阶段B。
