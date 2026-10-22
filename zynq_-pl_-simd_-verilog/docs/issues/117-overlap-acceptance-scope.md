# 117：重叠模块通过不能冒充严格实时整机通过

状态：已修；验收脚本与探针已补充，授权实施后256窗SoC严格验收及匹配当前RTL的40MHz完整实现均PASS。实际几何和实板未验收；以下保留原问题及模块FAIL证据。

## 症状

已有独立TB输出`STRICT_REALTIME_MODULE_PASS`，但未提供每个窗口完整可用到结果有效
的端到端时间戳，没有SoC音频或当前实现证据。旧访存报告仍固定输出“RTL未改/CSR缺陷”。

## 误判

不能把模块内部`start_tick`到计算结束的延迟等同于窗口最后一个样点到达后的延迟；
不能用4个模块窗口证明256-Hop整机、音频、实现时序均已通过。

## 根因

原TB只看模块自报latency，不记录窗口ready/result时间；统计脚本没有严格验收入口。
旧访存汇总将`rtl_changed=False`和“CSR缺陷”写死，没有根据当前构建和测量判断。

## 修法

TB独立记录最后样点到达、结果完成，逐窗检查12×1024原始样点并记录真实执行次数。
`check_overlap_localizer.py`输出JSONL及strict_summary；新增`check_overlap50_strict.py`
从输入样点覆盖推导全部候选窗，检查序号、阶段数、黄金结果、间隔、逐窗延迟、
积压、损失、256窗口、SoC音频和匹配当前构建的40MHz实现证据。
模块音频未知明确记null，不能冒充0；MODULE范围与缺失时序使整机判据FAIL。
访存报告新增目录参数、构建source hash和动态CSR/退休一致性判断。

## 复现指纹

`wsl python3 scripts/test_overlap50_strict.py`：17类验收正反例通过，
其中正例只是检查器合成事件，不能算硬件验收。
`wsl python3 scripts/check_overlap_localizer.py --windows 16`：真实模块数值验证，
其`SCHEME_A_FAIL`是整机证据不足的正确判定。完整结果见
[执行报告](../pdm12_taskbook_execution_20261015.md)。

当前整机入口：`scripts/summarize_localizer12.py build/localizer12/final256 --implementation build/localizer12_final/implementation`，输出LOCALIZER12_STRICT_PASS。所有256窗、255个524288拍间隔、393217拍延迟及131968点音频零丢样通过；来源哈希必须匹配当前RTL/ROM和实际实现报告，详见[最终实现报告](../pdm12_transfer_bram_implementation_20261015.md)。
