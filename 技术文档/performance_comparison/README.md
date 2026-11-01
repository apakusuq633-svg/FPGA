# 九麦系统性能对照实验

本目录保存2026年10月28日实际执行的对照实验。测试程序、固定输入、编译产物、源码与工具哈希、原始日志、逐次时间样本和汇总结果集中保留，不依赖拟删除的技术说明文档。

当前没有连接Zynq板卡，按要求先完成RTL仿真和Windows宿主测试。RTL周期可以按40 MHz换算为设计时间；x86宿主时间仅说明本机软件成本。两者均不能填成Cortex-A9实板耗时，不能跨平台相除冒充三架构整机加速比。

## 文件组织

| 位置 | 内容 |
|---|---|
| `pl_rtl/` | 隔离源码镜像、重建九麦固件、当前SoC连续窗口计时、RV32标量与硬件FFT/FIR对照 |
| `circular9_scalar/` | 完整九麦标量C参考、RV32执行及宿主计时；与加速首窗统计／频谱／相关／评分逐级对齐 |
| `rtl_primitives/` | 同输入SRP串行/单流水/四麦对并行；FFT稀疏输入与标量黄金参考 |
| `ps_software/` | 当前PS搜索四种开关组合、精确整数除法、历史/当前包络前端的宿主计时 |
| `ps_software/full_modules/` | 完整GSC适应／旁路与完整双候选快照分离；先验证有效路径，再计时 |
| `hardware_probe/` | 只读JTAG枚举与设备检查；目标数0，没有烧写或复位 |
| `suite_runs/` | 总入口每次调用的命令、运行顺序、日志与退出码 |
| `results_summary.csv`、`results_summary.json` | 从原始结果生成的统一结果索引，保留平台、计时范围、样本数及来源哈希 |
| `run_suite.py` | 串行复现入口；先测宿主，再编译/运行RTL，避免本套程序互相争抢CPU |
| `run_primitive_checks.py` | SRP/FFT模块检查入口；输出只写入本实验目录的新时间戳目录 |
| `collect_results.py` | 汇总已测结果；不会把缺失板测填成估计数 |
| `verify_bundle.py`、`bundle_verification.json` | 核验源码／产物哈希、统一表、文档同步及图中数值；不重新跑计时 |

## 复现命令

从工作区根目录执行。以下程序默认不连接板卡，也不改动生产RTL或固件。

```powershell
# 完整复现：宿主软件、九麦SoC与算子、SRP/FFT局部RTL
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/run_suite.py'

# 只运行某一组
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/run_suite.py' --suite host
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/run_suite.py' --suite pl --reuse-pl --windows 32
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/run_suite.py' --suite primitives
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/run_suite.py' --suite full-modules
# scalar依赖pl组已生成的当前输入、源码镜像与dump；all会自动先运行pl
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/run_suite.py' --suite scalar --reuse-pl

# 只核验正式宿主结果，不重新计时
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/ps_software/verify_results.py' 'performance_comparison/ps_software/measured_20261028_host_quiet/results.json'

# 汇总本次选定的正式结果
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/collect_results.py'
# 核对本次冻结记录及已回填的比赛文档
& 'C:/msys64/ucrt64/bin/python.exe' -X utf8 'performance_comparison/verify_bundle.py'
```

工具位置记录在脚本及结果中：MSYS2 UCRT64的Python/GCC/Icarus/Verilator，MSYS2 Perl，以及AMD 2025.2的RISC-V GCC。换电脑时先调整工具路径。宿主测试应避开综合、编译、游戏等其他重负载；脚本不锁CPU频率，也不剔除Windows调度离群值。

`--reuse-pl`复用已有的隔离源码镜像和模型，适合重放当前冻结版本。生产源码有变化时不要使用此参数。PL入口在自己的固定实验目录重建产物；需要保留多个PL版本时先完整归档该子目录。宿主和模块检查使用新的输出目录，避免覆盖既有轮次。

总入口默认32窗。`collect_results.py`默认选本次固定正式目录，不自动取新一轮的最快结果；汇总新宿主轮次时显式传`--host 新目录/results.json`、`--full-modules 新目录/results.json`，模块新轮次可传`--primitives rtl_primitives/run_时间戳目录`。PL和完整标量实验为固定路径，重跑前需归档希望保留的旧版本。

## 已取得的结果与计时边界

| 实验 | 本次结果 | 能支持的结论 |
|---|---|---|
| 完整九麦定位评分，标量／加速 | 同一首窗11049372→82354拍，即276.234300→2.058850 ms；134.1692倍 | `-Os`同任务RTL；输入驻留→1024评分，不含PS往返／峰值及质量后处理／发布，统计前移属于架构差异 |
| 九麦连续定位，32窗 | 首个PCM到RV32稳定发布9.172325—9.176225 ms，按40 MHz换算 | 当前加速生产路径的仿真延时；含该1024点窗1023个采样间隔，不含模拟/PDM启动、PS接收及网络 |
| FFT，1024点实数 | 179036→6602拍，27.1184倍 | 同输入完整调用；含装载／运行／取回，1026个int16全等 |
| FIR，512点／32抽头 | 276774→15138拍，18.2834倍 | 原函数执行，标量和SIMD各512点与独立整数参考全等 |
| SRP，36麦对×1024方向×64相关点 | 串行147458拍、单流水37153拍、四麦对9307拍；相对串行15.8438倍 | START到DONE的模块扫描加速，不含装载与读回；串行RTL不是RV32标量整机 |
| PS搜索，单宽带 | 参考8.0546 ms→组合6.1932 ms，均值比1.3006倍 | Windows x86同函数、同输入、同输出的算法实现优化 |
| PS搜索，三源分频混合 | 参考8.2452 ms→组合5.9606 ms，均值比1.3833倍 | 四种开关反馈与3072个整数评分一致；场景实际输出两个候选，不代表三个声源全部检出 |
| GSC整数商专项 | 原生除法0.3520 ms，共享倒数1.5140 ms，均值比0.2325倍 | x86本机出现负收益；131072个商逐项精确一致，ARM32收益需另测 |
| 包络前端演进 | 历史8.2765 ms→当前2.0698 ms，成本比3.9987倍 | 历史与当前滤波、观察窗口和特征契约不同，不能当作数学等价加速 |
| 完整GSC，32768点 | 旁路18.168 ms，启用适应23.696 ms | 每模式31次；全部计时体进入真实适应，功能成本不同，不给等价加速比 |
| 完整双候选分离 | 平均56.866 ms，P95 60.682 ms，最大67.097 ms | 31次，160256×9→两路各40000点；两个输出均有效，实际协方差参与，非失败快速返回 |

当前源的FFT/FIR结果以`pl_rtl/results.json`及汇总表为准；完整九麦标量评分对照见`circular9_scalar/comparison_summary.json`。标量`-O2`辅助行9806381拍，与同首窗加速端相比119.076倍；宿主标量9轮×64次批均值中位0.334117 ms，仍不代表A9。32窗全部统计／评分、首窗频谱／相关全等。任何失败调试记录保留原状，正式表只采用明确通过的结果。

初期隔离构建发现链接器默认插入36字节GNU build-id、而TB只将.text装到0地址，导致链接地址与装载地址错位。实验链接已加`--build-id=none`并断言ELF入口与.text VMA为0，随后所有正式数值和周期重新验证。此修正只作用于实验镜像；错误构建结果已排除，不能用其周期补正式表。

正式宿主结果为`ps_software/measured_20261028_host_quiet`；第一轮并发环境及烟雾调试仍保留，未挑选最快轮作为主表。搜索每变体每场景41次，除法每变体101次，包络每变体31次；各有一次验证调用及5次预热，均不计入稳态统计。合计592条计时记录，mean/P50/P95/max均保留。

完整模块正式结果为`ps_software/full_modules/measured_20261028_full_quiet`，另有93条计时记录。对应`verify_full_results.py`可重算统计与核验哈希。完整九麦宿主标量另保留9个批时间样本，每批64次；批均值分布不能称为逐窗P95/P99。

SRP既有结果完整保留在`rtl_primitives/measured_20261028`；`run_*`为新的复现轮。模块TB周期10 ns，毫秒列统一按产品40 MHz解析换算。SoC与RV32算子TB周期25 ns。不要将不同TB的模拟器运行秒数当作电路执行时间。

## 三架构主表的验收条件

最终PL-PS标量、PS-ONLY、PS-PL向量必须使用相同九路PCM、标定、频带、1024点窗、36麦对及1024方向格，并先检查输出一致性。分别记录：输入可用到评分完成、后处理/发布，以及PS发起到取得有效结果的全程。PL向量方案包含FFT和SRP专用硬件，不能把全部收益写成SIMD贡献。

当前阶段可验证PL执行周期及宿主算法成本。仍需板卡与匹配bit/XSA/BSP/ARM ELF后实测：A9同任务时间、PS控制传输及接收、三架构全程、NEON独立开关、双核满负载、至少1000个有效稳态窗、CPU占用与丢样、资源功耗及真实声场精度。旧八麦、旧GSC或不同轮次的记录不填入当前九麦三架构主表。
