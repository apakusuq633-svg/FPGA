# 094 SRP 累加存储器多驱动

**症状**：DAS/FIR 全器件综合时，Vivado 报 SRP p_mem 多驱动/忽略部分写入；RTL 定位回归却通过。

**误判**：单凭定位仿真通过，可以误认为 SRP 的硬件存储结构正确。

**根因**：p_mem 同时由同步 RAM 块和状态机的复位/启动清零循环驱动，破坏 RAM 单写端结构。

**修法**：rv32_srp_scan.v 保留唯一同步写端；第一对相关序列将 old_p 当作零，实现逻辑清零；result_valid 在开始/复位清零，全部网格完成后置位。忙或结果未完成时公共 P 读口返回零，空闲有效结果通过同一同步 RAM 端口读取。

**复现/指纹**：scripts/test_das_release.sh 覆盖 tb_srp_scan、tb_srp_regs 的完整扫描；Vivado 全工程综合日志检查 p_mem 多驱动警告。不能以综合退出码替代显式 SYNTH_OK/FLOW_PASS 和时序报告。
