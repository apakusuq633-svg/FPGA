# 116：minstret对停顿期间保持的WB指令重复计数

状态：当前已有退休门控修改，2026-10-15仿真复核通过；对应新RTL实现/实板未验收。

2026-10-15：进入工程时`retire_i`已经接到`memwb_valid & ~memory_stall & ~halt_i`。
本次76场景复核`minstret=100847 exported_retire=100847`；未门控WB电平累计129370，
差28523恰好等于held-WB，说明重复电平未再次进入CSR。日志在
`build/taskbook_20261015/mem/simulation.log`。以下缺陷描述保留为历史复现。

## 症状

微基准CSR minstret=126784，真实导出退休事件100846，多25938。退休store实际写入次数仍正确，不是指令重复执行。

## 误判

不能用CSR minstret直接作为当前CPU的真实退休数，或把它与PS的RETIRE_CNT当成同口径。rdcycle另用mcycle，不受这个问题影响。

## 根因

`rtl/core/rv32_core.v:324`的CSR retire_i接memwb_valid；MEM等待时MEM/WB保持valid。CSR每拍增加计数，而`retire_valid_o`在line969用memory_stall/HALT门控。TB独立计数25938次held-WB与多计数量完全一致。

## 修法

本轮只加测试探针，所有性能报告使用导出的单次退休信号。建议CSR输入与现有retire_valid门控对齐；具体补丁与回归见`docs/perf_rv32_optimization_plan.md`的C0，未获批准不实施，不能把现有回归PASS说成已修复此缺陷。

## 复现指纹

`wsl python3 scripts/check_rv32_mem_perf.py`，`build/rv32_mem_perf/simulation.log`：`CSR_RETIRE_AUDIT minstret=126784 csr_input_events=126784 exported_retire=100846 held_wb_events=25938`，并断言差值归因一致。功能`rtl/` diff为空。
