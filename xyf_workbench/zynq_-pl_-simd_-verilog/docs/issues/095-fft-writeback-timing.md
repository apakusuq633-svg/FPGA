# 095 FFT 写回路径时序余量

**症状**：八路 DAS/FIR 全工程实现虽然通过，WNS 仅 +0.004ns。FFT 路径从 twiddle BRAM 经乘加和选择逻辑到 LUTRAM 写入，诊断路径包含约 18 级逻辑。

**误判**：只检查 FPGA 能生成 bit，忽略时序余量很小；或直接添加寄存器而不考虑最后一次 RAM 写入尚未完成。

**根因**：算法写回组合逻辑与 RAM 写入口未分隔；分级、拆分和逆变换末尾需要等待流水写入排空。

**修法**：在 rv32_fft_bfly 的算法写回路径加入 wr_dat_q/wr_adr_q/wr_en_q；阶段末尾及拆分/逆变换末尾增加排空周期。标量 PUSH 单周期写入保持原协议。

**验证**：scripts/test_das_release.sh 覆盖正/逆 FFT、满幅整数参考及真实固件。最终 40MHz 全工程实现 WNS +0.060ns、WHS +0.034ns，setup/hold 失效端点均为零。固件硬件 FFT 从 7615 增至 7625 拍，数值结果不变；连续音频并发压力最大仍为 76 拍。该余量仍小，后续 RTL 修改必须重新实现。

**证据**：build/das_fir_before_writeback 中保留前版报告；当前 build/timing_zynq.rpt、build/das_fir_zynq_console.log、build/acoustic_rtl.log 和 build/das_stream.log 为最终证据。仿真和 STA 不代替实板声学验收。
