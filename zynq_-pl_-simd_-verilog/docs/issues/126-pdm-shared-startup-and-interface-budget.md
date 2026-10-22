# 126 PDM启动有效性与外部接口预算

状态：RTL/仿真已修；真实载板、供电和完整外部时序仍待验。

## 症状

PDM输入原为整条false_path；首A位发生在首次下降沿之前；数字PCM valid从第1022拍起发布，没有麦启动/滤波器稳定门控。旧采集TB的200000拍上限不足以等待新增50ms门控。

## 误判

不能把“没有IDDR”当成错误，也不能把数字同拍视为声学采样同时。旧M6与本次前基线有两个独立延迟三态源，不能沿用更早审计中“所有现存测试均无独立三态驱动”的结论。M6测试仍缺生产启动门控。

## 根因

有效PDM数据只在各自半周期内成立；原约束不检查返回路径。sample_valid原本仅代表抽取节拍，缺少启动质量限定。旧TB假定启动时间为零。

## 修法

保留HOLD=4/CONSUME=12、每麦2.5Mbit/s和12个CIC。忽略第一对不完整PDM位；默认等待2,000,000拍，之后排除4个CIC帧再发布。零/零参数仅为显式raw诊断。XDC用5ns输入路径、10ns含clk-to-Q的CLOCK输出路径预算替代PDM整条false_path；datapath_only隐含忽略hold STA，hold改为独立外部窗口解析（假设区间下76ns）。所有PCB、FF与时钟偏斜预算均非板测。

## 复现指纹

`python3 scripts/check_pdm_shared.py --output <fresh-output>`：正常/交换/缺A/缺B/延迟边界、16种停启相位、随机/固定码、50ms全参数、冲突及迟到反例。`python3 scripts/check_pdm_integration.py --output <fresh-output>`：capture39项、RV32 SoC、PS AXI。旧capture测试使用4096拍缩放等待，但保留4帧清除；完整默认参数另测。证据统一在 `build/pdm_shared_remediation`，最终状态见整改报告。
