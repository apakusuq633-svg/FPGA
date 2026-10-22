# 128：PDM验收自动化与PS bank错误传播

状态：软件错误处理已修，自动化及独立RAM实验结果见本轮报告；板级UNVERIFIED_HARDWARE。

## 症状

外部窗口原先是独立报告，缺少统一非零失败入口。PS遇到META非法时继续循环并最终成功；读取期间SEQ改变或RELEASE被拒绝也可能静默成功。

## 误判

不能把“生成了24条报告”当作已检查裕量，或把read_bank返回错误后继续程序当作正常完成。隔离模块BRAM变少也不证明完整SoC布局或连续计算通过。

## 根因

缺少逐端点强制验收、当前源码/DCP绑定及PS/STA聚合入口；PS错误未上抛，未复核bank所有权及释放结果。SRP和RAW非整深RAM被自动深度扩展，容量利用率需通过真实映射实验确认。

## 修法

新增accept_pdm_project.ps1统一入口、显式板级假设、12端点24路径检查及失败注入。PS返回错误时立即退出，读取后确认SEQ，释放后检查是否仍为同SEQ的READY bank；修正12位frozen掩码。RAM只生成build下bank分段候选，生产RTL不替换，按原数值/64窗连续/完整实现门控。

## 复现指纹

原PS四个错误场景返回成功；修复后12场景通过，包含FRAME/SEQ回卷、重启、同slot立即补满、无首帧/无bank、非法长度、SEQ变化和拒绝释放。ARM GCC9.2.0编译链接通过。STA自动化负例实际退出1，缺端点/负裕量/例外/不完整manifest均被拒绝。

模块隔离结果：SRP32→23.5、Localizer25→21 BRAM36等效；完整SoC与最终验收以[本轮报告](../PDM验收自动化与RAM实验报告_2026-10-16.md)为准。64窗候选与基线均2359296次RAW比较、33664个音频输入/输出、drop0、max_compute321794、max_latency393217、max_gap524288，TEST_ONLY几何。

最终完整SoC：111.5→99 BRAM，WNS+0.257ns/WHS+0.018ns，TNS/THS0、全部54228条网络布线；最终外部24检查通过，最差Setup/Hold+4.907/+81.079ns。默认DRC仍471项Warning、无Error/Critical Warning，不等于零告警。聚合final_acceptance.json=PASS_ISOLATED_EXPERIMENT，63个生产RTL及XDC未替换，硬件UNVERIFIED_HARDWARE。
