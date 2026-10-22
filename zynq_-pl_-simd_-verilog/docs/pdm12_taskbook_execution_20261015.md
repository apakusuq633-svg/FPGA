# 三份PDM任务书执行复核：2026-10-15

后续连续运行风险验收已进一步修复故障隔离、HALT/WB、计数回卷和退休握手；最新1024窗非周期证据及匹配40MHz实现见[连续运行安全报告](localizer12_realtime_safety_report.md)。下文保留原任务书阶段记录及其构建口径。

当前状态：用户“进行修改”已授权A-RTL-118选项3，已完成自主搬运、核指令计算和BRAM流水接入。
**256窗SoC严格仿真PASS，40MHz完整实现PASS（WNS +0.622ns / WHS +0.030ns）**。
当前实现、证据与边界见[最终实现报告](pdm12_transfer_bram_implementation_20261015.md)。未下载板卡，实际几何仍禁用。
以下是授权实施前的历史复核记录；其中FAIL、待批准、未接入和RTL未改均描述当时快照，不是当前状态。

## 版本、范围与文件

HEAD：`10f6c3a2ea686d82a2418cc175c757bd4df22076`，工作区已有未提交修改。
三份Downloads任务书与`docs/PDM_12_taskbook.md`、`PDM_12_overlap_taskbook.md`、
`PDM_RV32_mem_taskbook.md`逐字节SHA256一致，记录在
`build/taskbook_20261015/taskbooks.json`。
本轮进入时就存在core退休门控、fetch保持请求、SRP FAST_SCAN与独立硬件定位模块，
不能将它们写成“本轮从零完成”，也不能继续沿用旧报告“RTL未改”的当前状态描述。
保留全部原有源码修改；此前板级数据只作其原构建的历史证据。

本轮修改测试/统计：`tb/tb_overlap_localizer.v`、`scripts/check_overlap_localizer.py`、
`check_overlap50_strict.py`、`test_overlap50_strict.py`、`check_rv32_mem_perf.py`、
`report_rv32_mem_perf.py`、`check_overlap_localizer_synth.tcl`；同步台账/问题档案。
移除这些新增探针/脚本即可回退本轮测试改动，不触及继承的功能RTL。

## 源码事实与边界

- `rtl/core/rv32_core.v:324`：CSR退休输入已有memory_stall/HALT门控。
- `rtl/core/rv32_fetch_stage.v:44`：已有保持ITCM请求的实现。
- `rtl/soc/rv32_dtcm.v:93`：同步RAM应答机制仍保留，未强拉ready常高。
- `rtl/array/rv32_pdm_capture.v:103`附近：ACKSEQ/RELEASE验证所有权；
  DATA不自动增址，512点×6字=3072字/新半块，不能删去必要INDEX/同步读等待。
- `rtl/soc/rv32_soc.v:368,420,460`附近：连续DAS、capture、原SRP实例；
  **没有实例化`rv32_overlap_localizer`**。独立模块结果不等于SoC已接入。
- `configs/production_array.json`：实际XYZ、物理映射、坐标轴仍null；
  生产geometry_enabled=0，测试几何仅用作算法与资源评估。

## 已完成复核

| 工作 | 当前实测 | 判据/范围 |
|---|---|---|
| 76场景访存 | 28534事务；CSR100847=exported_retire100847；音频128/128、drop0、max101拍 | 仿真PASS；长度1/16/256/1024，带数据/副作用检查 |
| 8场景展开MMIO | 2594事务，1024次读/写各2048拍 | 仿真PASS；约2 cycles/access |
| 展开DTCM | 1024次读/写各2050拍，含2条中段指针调整 | 归档3072拍→当前2050拍；不同RTL构建，非纯固件A/B |
| 请求→应答 | 请求边沿到应答边沿1拍；含两端MEM占用2拍 | 未将CPU吞吐混同RAM延迟 |
| 既有回归 | SoC、PS、units、SIMD、FFT、IFFT、capture共7项PASS | `check_rv32_mem_regression.py` |
| 拼窗/滑窗和 | 273宿主窗口；SEQ/FIRST回绕、忙消费者、缺口、复位通过 | HOST PASS，不能替代连续SoC Bank服务 |
| 融合预处理 | 260场景FFT输入误差0 | HOST PASS，含符号端点/DC/弱源/静音 |
| 几何门控 | 66对唯一，缺失信息/越界负例/测试几何隔离通过 | 不输出虚构实物角度 |
| 非完整链五段 | 931766拍；capture340113、prepare512811、PUSH36938、RUN11028、POP30876 | 当前12FFT profile；GCC/SRP/转向=0，不是完整定位 |
| 非完整链RESULT | compute933444、total1981550；两快照音频3870、drop0 | 含/不含采样等待分别列出；100MHz TB周期按40MHz折算 |
| 严格检查器 | 17类正反测试PASS | 包含缺窗、缺首窗积压、重算、少算、旧结果、几何关闭、丢样、超时、时序证据缺失 |

当前访存四事件表及CSV在`build/taskbook_20261015/mem/`。
归档的3 cycles/access、CSR过计25938与旧实板76项一致性不是新RTL的板级证明。
当前主访存manifest记录源码SHA256；报告动态判CSR/退休一致，不再固定输出旧缺陷。

## 当前RV32完整快照链复核

`build/pdm12_runs/taskbook_20261015/`：四帧实际运行48路正FFT、264对GCC/PHAT/IFFT、
4096个SRP分数，FFT/PHI/完整相关/32点环与golden逐位一致；score_errors=0。
连续音频14375样点、drops=0、max101核心周期；此测试仍是100MHz时钟TB的周期测量，
时间按目标40MHz折算，不作为40MHz实现或物理麦克风精度证明。
模式为`-O2/FW_CYCLE_PROFILE/FW_NUMERIC66/FW_GCC_AUDIT/FW_PREPARE_FUSED/FW_TEST_SRP/FW_MEM_PROFILE`，
保留完整ELF/MAP/反汇编和源码hash，未用几何关闭分支代替算法。

| 算法阶段 | 均值cycles | 最大cycles |
|---|---:|---:|
| capture+统计 | 332855.75 | 332989 |
| prepare | 406530.75 | 406756 |
| 全正FFT PUSH | 36946.5 | 36972 |
| 全正FFT RUN | 11064 | 11064 |
| 全正FFT POP | 30942 | 30960 |
| 66对GCC/IFFT环路径 | 601684 | 601696 |
| SRP区间含marker外围 | 304149.25 | 304204 |
| 上述算法阶段合计 | 1724172.25 | 1724500 |

同向量/同O2插桩的旧`mem_full_chain_o2`阶段合计1922374→当前1724172.25，
节省198201.75拍/10.3103%；这是继承的CPU/SRP工作区修改共同结果，不能全归因某一行RTL。
仍比Hop预算多1199884.25拍；GCC本身已超过预算77396拍。
完整compute=2632036平均、2632355最大，含额外完整IFFT核对429668.5和PHI审计复制474804.5，
不能把这两个测试开销当生产算法必需，也不能反过来把阶段合计冒充端到端重叠延迟。
total含采样等待均值3679908.5、最大3680207，FIRST为0/3594/7188/10782，显然不是512帧移。

实际LSU等待探针如下，单位均为四帧均值核心周期，非rdcycle阶段差值：

| phase | 用途 | total residency | MMIO | DTCM | scratch | LSU合计 |
|---|---|---:|---:|---:|---:|---:|
| 1 | capture | 333011.75 | 18444 | 306 | 12288 | 31038 |
| 2 | prepare | 406260.75 | 0 | 12300 | 36864 | 49164 |
| 3 | FFT PUSH | 37006.5 | 0 | 0 | 6144 | 6144 |
| 4 | FFT RUN | 11052 | 0 | 0 | 0 | 0 |
| 5 | POP附近 | 32436 | 0 | 384 | 6156 | 6540 |
| 6 | 互谱/PHAT/填零 | 334707.5 | 0 | 35178 | 27456 | 62634 |
| 7 | IFFT/环回读 | 267438.5 | 0 | 34056 | 1056 | 35112 |
| 9 | SRP | 304149.25 | 41827 | 1328 | 3136 | 46291 |

有效阶段LSU等待共236923拍，是删除所有可见等待的宽松上界，包含与SRP扫描重叠的轮询。
即使假设全部可省，阶段合计仍1487249.25拍，超过预算962961.25拍；仅继续改ready无法达标。
采样等待phase0和额外审计phase8不叠加进上述有效阶段；其它未可靠分类的等待仍为UNKNOWN。
原始CSV见`build/taskbook_20261015/mem/application_stall_breakdown.csv`。

## 独立完整算法重叠模块

运行16连续窗，FIRST=0,512,...,7680。输入按真实1024核心周期/PCM样点节拍驱动，
时钟25ns；包含9143个12路合成PCM输入样点。使用2048点周期向量和4窗参考循环，
包括满幅交替通道与DC通道；不代表真实声场覆盖。

- 196608个原始窗口样点逐点一致，192路正向FFT频谱、1056对互谱/PHAT/IFFT
  相关环、16384个SRP分数与固定点golden逐位一致。
- 每窗12FFT/66对/66IFFT/1024格点均真实执行；窗口ID和FIRST连续。
- 外部测量ready→result均为449582拍=11.23955ms；旧内部449574拍不含8拍外围延迟。
- 15个结果间隔均524288拍=13.1072ms；均值/P99/最大值相同，但16窗不足以证明长期尾部。
- 原始丢块0、跳窗0，积压峰值1、每次完成后0；模块没有DAS/FIR，audio_drops=UNKNOWN。
- 对预算余量74706拍/14.2482%，未达建议20%余量，未降低工作量通过。

原始日志/结构化事件/严格结果：`build/strict_overlap/module/`。
`STRICT_REALTIME_MODULE_PASS`只表示上面的模块局部条件。
严格脚本正确输出FAIL：MODULE非SOC、音频未测、仅16窗、无当前整机实现证明。
未运行256-Hop整机；不能声明A-L2/A-L4通过。

## Vivado资源反证：候选模块当前无法布局

命令：`vivado.bat -mode batch -source scripts/check_overlap_localizer_synth.tcl`。
Vivado2020.2，part=`xc7z020clg400-1`。OOC顶层连接完整localizer、VFFT、FAST_SCAN SRP；
不是仅对控制器空壳综合。综合成功，布局前DRC失败，退出码1：

| 指标 | 实测 |
|---|---:|
| LUT | 29573 |
| FF | 2496 |
| BRAM tile | 29 |
| DSP | 78 |
| LUT as Distributed RAM | 17468 / 17400（100.39%） |
| WNS/WHS | **NOT AVAILABLE：place_design未执行成功** |

`srp/lut_mem_reg`推断为128K×9分布式RAM，3168个RAM64M；
`srp/r_mem_reg`也使用分布式RAM。实际布局DRC `UTLZ-1`同时报LUTRAM/RAMD64E超限。
没有降低DRC严重级别，没有将缺失时序当作0ns通过。
此前整机28383LUT/15684FF/84.5BRAM/131DSP仅属旧实现，不能相加当作新整机实测；
简单复制候选还有资源重复问题。完整日志`build/strict_overlap/ooc_vivado.log`，
综合资源`build/strict_overlap/ooc/utilization_synth.rpt`。

## A-RTL-118：已获授权并完成选项3（以下保留原评审记录）

任务书`PDM_RV32_mem_taskbook.md` Phase4要求：
“功能性RTL改动，先向用户展示具体补丁设计和预计收益，等待批准”。
`PDM_12_overlap_taskbook.md` Phase6 Gate6要求提交架构选项并停止在授权边界。
因此不能仅凭“最终完成方案A”自动改变RAM映射和SoC资源仲裁。

| 选项 | 具体变化 | 机会与约束 |
|---|---|---|
| 1 固件早取块+双缓冲 | 保留capture端口，ACK前复制新3072字；只保留原始两半；安排CPU分段服务 | 不额外复制硬件算子；CPU现有完整GCC单段仍超Hop，不能单独解决严格吞吐 |
| 2 增Bank/块FIFO | 在capture增加512点槽，每槽12288字节；明确SEQ/FIRST/ACK版本 | 原始容量每新增槽理论至少3个RAMB36（实际因端口/宽度更多）；只能延缓拥塞，不能改善平均计算预算 |
| 3 流式localizer+存储重映射/算子复用（推荐评审） | 从`pdm_aligned/pdm_valid_aligned`旁路写原始环；SRP LUT显式验证BRAM映射；通过有所有权的接口复用既有VFFT/SRP，避免直接复制整套LUTRAM | 模块已测449582拍是可行性线索；改变映射、端口或所有权后必须重测，不能保证仍维持该数值 |

推荐选项3的补丁范围：

1. `rv32_srp_scan.v`：先独立实验LUT的BRAM推断约束和17位地址边界，保持既有同步读延迟；
   相关环双读、P读写旁路与pair/grid边界依赖逐项验证。若需加流水级则单独列延迟变化。
   LUT有效数据67584×9=608256bit，理想容量下限17个36K BRAM；实际映射须综合测量。
2. `rv32_soc.v`、`rv32_core.v`、`rv32_execute_stage.v`及`rv32_srp_regs.v`：
   增加事务边界的算子所有权接口；保留CPU原指令编码、MMIO地址/副作用、PS HALT契约。
   localizer占用VFFT/SRP时不能让CPU误收其done/result；并发请求必须等待或按批准方案仲裁。
   FIR现有8lane与其音频优先路径保持，复用的是定位FFT/SRP资源。
3. `rv32_overlap_localizer.v`：确认输入ID连续、窗口不可变、峰值存储和最坏服务时限；
   接入SoC时配置默认关闭，仅TEST_GEOMETRY_ONLY可在仿真中启用；真实坐标缺失仍禁止转向。
4. 固件/PS：先用既有控制完成SRP LUT装载和阶段切换；如需新增只读状态寄存器，
   列出保留地址与版本，另随补丁审批，不擅自复用已有寄存器。
5. TB先验证完整SoC同窗12FFT/66对/1024分数、连续FIR数值和drops=0，再做256+Hop。
   完整40MHz实现必须WNS/WHS均非负；任何资源超限、错窗或掉样都FAIL。

带宽/存储约束：每Hop6144个新16位PCM，3072个packed字；采集平均需求
3072/524288=0.005859375字/拍。原始2048点环需49152字节，1024点窗24576字节；
复用同一环必须证明读完前不会覆盖。当前模块有效频带208bin/通道共2496频谱字，
每窗12FFT+66IFFT；模块cycle已经包括这些真实工作。SRP每窗67584个pair/grid贡献，
LUT读端口/R双读/P读改写同时决定吞吐。不能仅按平均采集带宽判断整个架构达标。

资源和时序：选项3的最终增量**UNKNOWN**，必须先用OOC实验和完整整机报告验证。
当前未获批存储/仲裁补丁，无生产可用bit/XSA；旧位流不可验证新代码。
回退：独立编译参数默认禁用localizer、保留原CPU/GCC/SRP路径及旧匹配构建，
每次只更改一个资源或仲裁点，失败即撤销本次实验补丁，不覆盖进入本轮前的用户修改。

## 2026-10-15追加：BRAM访问与物理布局约束

用户明确补充：此前曾因布局布线延时放弃BRAM；本轮大容量存储若改回BRAM，
必须同时缩短访问路径，并使对应计算逻辑靠近所用BRAM。此节是设计约束，
不是已完成映射/布局的结论，也不代表额外授权其它SoC/ISA架构改动。

1. 大容量原始PCM、频谱和SRP延时表按实际端口需求评估BRAM；小型、高并发的
   操作数缓存可继续采用局部寄存器/LUTRAM。禁止把多路异步读数组直接加block属性
   当成优化完成，尤其FAST_SCAN相关环存在两个组合读，需要明确银行划分或流水化方案。
2. 采用局部路径：地址寄存器→同步BRAM→可选BRAM输出寄存器→邻近算子→结果寄存器。
   把bank选择/地址运算和复杂算术拆开，避免BRAM输出后继续穿过全局多路器和长加法链。
   对可持续顺序搬运，设计目标是流水线充满后每拍接受1个32位字；首字延迟、尾部排空、
   端口冲突和暂停须单独测量，不能承诺所有阶段均一拍完成。
3. 按用途分bank和模块层次，使读写控制、BRAM及消费算子形成局部簇；不能把整个系统
   放在单一共享RAM后面再通过宽全局交叉开关连接。双缓冲只在所有权和容量证明后启用。
4. BRAM/DSP物理位置固定，先查看实际映射、关键路径与拥塞，再用局部Pblock引导
   相关BRAM、DSP和逻辑靠近。首轮使用可调整的区域，不预先把所有实例硬锁到单点LOC，
   防止SLICEM/DSP不足、拥塞或共享路径变长；区域必须容纳所需资源并留布局余量。
5. 比较无区域约束与局部区域约束两种布线结果，记录关键BRAM相关路径的cell/net delay、
   logic levels、fanout、BRAM/DSP实际位置、WNS/WHS和拥塞。逻辑综合PASS不替代route结果；
   禁止用false_path/multicycle或降低DRC严重级别掩盖真实数据路径问题。
6. 接受增加必要流水级，但必须量化新旧首字延迟、持续吞吐、每窗最大ready→result时延。
   最终仍要求40MHz整机setup/hold通过、每Hop结果间隔和逐窗延迟均≤524288拍，
   输入/输出逐位一致、无错窗、音频drops=0；不能仅以LUT下降验收。

已有证据：本轮OOC日志明确提示raw_mem/spectrum等BRAM没有合并可选输出寄存器，
可能影响时序；尚不能据此证明其就是历史失败的根因。
旧`build/rv32_mem_perf/implementation/timing_zynq.rpt`的一个最慢setup路径为
u_xsp的DSP→索引寄存器，data path24.038ns，其中logic8.760ns、route15.278ns，
说明至少该旧构建存在显著布线成本，但该路径并非BRAM路径，不能冒充历史BRAM故障定位。
本轮候选因LUTRAM超限尚未成功place/route，BRAM映射方案的有效物理位置和延时仍须新实现确认。

## 复现命令

以下命令在`zynq_-pl_-simd_-verilog`执行；仿真/宿主工具通过WSL：

```powershell
wsl python3 scripts/check_rv32_mem_perf.py --output build/taskbook_20261015/mem
wsl python3 scripts/check_rv32_mem_perf.py --mmio-unrolled --output build/taskbook_20261015/mem
wsl python3 scripts/check_rv32_mem_regression.py
wsl python3 scripts/check_pdm12_geometry.py
wsl python3 scripts/build_live12.py --profile --numeric66 --fused --test-srp --mem-profile --hot-o2
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Twelve -CycleProfile -Numeric66 -TestSrp -SnapshotFrames 4 -RunTag taskbook_20261015
wsl python3 scripts/summarize_pdm12_run.py build/pdm12_runs/taskbook_20261015 --numeric
wsl python3 scripts/report_rv32_mem_perf.py --directory build/taskbook_20261015/mem --application-run build/pdm12_runs/taskbook_20261015
wsl gcc -std=c11 -O2 -Wall -Wextra -Werror sw/fw/fw_overlap12_test.c -o build/taskbook_20261015/overlap_host
wsl build/taskbook_20261015/overlap_host
wsl gcc -std=c11 -O2 -Wall -Wextra -Werror sw/fw/fw_prepare_fused_test.c sw/fw/fw_tables.c -o build/taskbook_20261015/prepare_host
wsl build/taskbook_20261015/prepare_host
wsl python3 scripts/check_cycle_profile.py
wsl python3 scripts/test_overlap50_strict.py
wsl python3 scripts/check_overlap_localizer.py --windows 16
wsl python3 scripts/check_overlap50_strict.py build/strict_overlap/module/events.jsonl --output build/strict_overlap/module/strict_summary.json
& 'D:\Vivado\Vivado\2020.2\bin\vivado.bat' -mode batch -source scripts/check_overlap_localizer_synth.tcl
```

strict命令退出1是预期的整机验收FAIL；OOC命令退出1是实测资源失败，均不能隐去。
其它上表通过测试退出0。宿主编译第一次遗漏`fw_tables.c`导致链接失败，补齐该依赖后260场景PASS。

## 最终分级

A-L1宿主拼窗已验证；独立完整硬件算法重叠的16窗正确性已验证。
A-L2真实SoC连续Bank/窗口/音频组合验收未完成；A-L3现有快照完整算法与独立模块
有数值证据，但尚未形成整机逐Hop链。A-L4资源布局失败、整机未接入、256-Hop未执行，
因此FAIL/INCOMPLETE。A-L5缺实物几何与板级场景，NOT RUN。
此历史授权边界已由用户“进行修改”解除；选项3及当前验证结果见本文开头链接。
