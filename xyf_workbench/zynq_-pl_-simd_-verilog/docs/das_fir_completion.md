# GSC 移除与 PL 收尾记录

日期：2026-10-11。实施依据：工程根目录《GSC移除与DAS_SIMD实施计划书_2026-10-11.md》。本轮只完成计划内八通道 PL 数据面与配套固件/验收，不替代实板声场验证。

## 已实现
1. 生产构建以固定 FIR 取代 GSC，验收/ARM/PS-only 使用相同整数内核与独立参考模型；归档 GSC 不参与生产链接或强制验收。
2. rv32_das_stream 接入八路真实对齐 PCM，64 样点历史、分数延迟、自动转向原子更新及 FIFO/错误/拍数计数。
3. 音频控制器在现有八路 SIMD-MAC 上执行 PUSH/VRED 固定 FIR；W1/XP3 与 CPU 的基准 W0 分离，仲裁覆盖 CPU halt 和并发向量请求，PS 系数窗口具备占用保护。
4. 新 RV32 原始采集 MMIO 镜像和快照模式；fw_live 从两个连续 512 样点 bank 读取真实 PCM，执行四对 GCC-PHAT、硬件 SRP、自然逐帧转向更新。定位计算不暂停连续增强音频。
5. 两套 ARM 下载/回读程序、DDR 链接、镜像哈希检查；生产程序默认十分钟消费测试及最近 4096 条音频 DDR 环形缓存。
6. Vivado 独立项目输出、实现时序硬门禁、bit/XSA 导出；上板脚本支持指定匹配 bit/init/ELF，避免覆盖旧项目产物。
7. 修复综合发现的 SRP RAM 双写端问题；替换正式验收中的旧 GSC 要求，增加真实 PDM 和破坏 FIR 结果的负向控制。

## 仿真证据
| 项目 | 结果 | 日志 |
|---|---|---|
| FIR 512 样点标量/SIMD | 292196/15714 拍，18.60×；整数指纹一致 | build/acoustic_rtl.log |
| FFT 标量/硬件 | 199026/7625 拍 | build/acoustic_rtl.log |
| 动态指令 | PUSH512 / VRED512 / VUPD0 / VFFT7182，fault0 | build/acoustic_rtl.log |
| 管脚位流到音频 | 64/64 非零样点与真实捕获 PCM 推导值逐点一致 | build/acoustic_rtl.log |
| 真实固件闭环 | 3 次定位、5280 条连续音频、锁定且无错误 | build/acoustic_rtl.log |
| 快照序号负例 | bank0/bank1 序号2/1，错误码2、定位0次 | build/acoustic_rtl.log |
| 连续流压力 | 1200 样点；CPU PUSH 并发最大76拍；溢出负例4条 | build/das_stream.log |
| PS-only 对照 | 14/14 独立参考比较 | build/das_release.log |

76 拍占每样点 1024 拍预算的 7.42%，低于 819 拍门限。这是 RTL 仿真测量，不是板上时序/实时性证据。上述角度 grid=123 仅说明位流合成场景可以完成定位，不代表实际声场角度精度。

## 工程验收入口
完整 RTL/模型回归：bash scripts/test_das_release.sh。ARM：scripts/build_acoustic_ps.ps1，生产版加 -Live。FPGA：设置 ZYNQ_PROJ_DIR=build/das_fir_zynq 后运行 scripts/run_zynq_flow.tcl。详细寄存器和判据见 acoustic_acceptance.md。

## 实现与预算
完整实现数字：Vivado 2020.2、xc7z020clg400-1、40 MHz，最终WNS=+0.060ns、WHS=+0.034ns，setup/hold失效端点均为0。LUT27745（52.15%）、FF14020（13.18%）、BRAM31.5（22.50%）、DSP175（79.55%）。裕量仍偏小，后续RTL修改须重新实现。

FFT写回增加一级寄存，级间与拆分末尾补排空周期：WNS从+0.004ns增至+0.060ns，硬件FFT固件拍数从7615增至7625，正/逆/满幅结果不变。DAS RAM控制改用同步复位，新增历史RAM的异步控制DRC警告已消除。

内部未约束端点、无时钟寄存器、组合环均为0。8条PDM DIN由原XDC显式false-path，采样窗口模型给出setup16ns/hold84.5ns（解析值，非板测）；4条未设output-delay是3个LED和PDM时钟输出。接口线缆/麦克风电气时序仍待实测。旧tacho同步器目标不存在的约束警告未匹配，也未屏蔽有效路径；当前tacho无RTL消费者，不宣称转速功能完成。

定位计算562361拍=14.06ms，含采集等待的快照周期1610650拍=40.27ms，约24.83Hz；连续音频仍为39.0625kHz。这是按计划门禁采用的“连续流音频＋周期定位快照”，不是原始bank无间隙。整机仿真对照：基准轮5351718/3750704拍（1.4269×），产品形态轮5061444/3450408拍（1.4669×），不含Cortex-A9自身周期。

产物：build/das_fir_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit、build/das_fir.xsa、build/acoustic_arm/live_das.elf。scripts/package_das_release.py检查XSA内bit一致性、双TCM哈希、时序及验收标记，输出build/das_fir_release_manifest.json；不替代ARM构建和物理验收。

## 明确未验证
用户确认暂未连接硬件，因此未执行烧录、物理麦克风数据、板上十分钟连续运行、定位准确度和定向增益测试。不能把仿真 PASS 写成物理 PASS。

固定输出 FIR 已满足本期 SIMD 复用目标；八路独立分数延迟 FIR、CIC 专用补偿、多波束、网络音频及诊断 PS 产品属于扩展项，不冒充本期完成内容。当前 DAS 使用线性分数插值；固定带限 FIR 不能恢复 GSC 的自适应干扰抑制能力。
