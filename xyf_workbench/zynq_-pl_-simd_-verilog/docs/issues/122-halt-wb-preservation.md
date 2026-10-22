# 122：HALT清空未退休WB指令

状态：已修，最终验收以[安全报告](../localizer12_realtime_safety_report.md)实际日志表为准。

## 症状

非周期输入在PHAT入口注入5000拍HALT，互谱只记录65次退休，预期66；原5000拍FFT入口测试没有覆盖该相位。组合突发同时观察到SRP分数不符。

## 误判

只门控retire_valid和CSR计数不能保证被HALT压住的WB内容仍然存在；单一阶段HALT通过不能推出任意相位通过。

## 根因

MEM/WB仅在memory_stall保持，HALT时valid_i被清零，当前尚未退休的数据被覆盖。HALT冻结EX/MEM不能替代WB保持。

## 修法

MEM/WB的hold加入halt_i，保留已有退休和寄存器写入门控。没有增加缓存或复制算子。修复后必须检查所有退休计数及音频逐点一致，不能仅看窗口done。

## 复现指纹

`build/localizer12_safety/before_audit/halt_phat_5000_w0_o0_n4_s20261015.log`为CUSTOM_COUNT失败；调试日志明确cross=65。对应修复后场景及组合压力日志在after_audit和最终release目录，原FAIL保留。
