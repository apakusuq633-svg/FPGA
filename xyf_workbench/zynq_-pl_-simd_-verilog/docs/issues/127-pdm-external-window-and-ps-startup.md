# 127：PDM外部窗口检查与PS首帧测量顺序

状态：软件顺序已修、条件STA已复核；实际载板UNVERIFIED_HARDWARE。

## 症状

输入max datapath报告不能证明外部Hold；PS示例可能在50ms门控内就统计FRAME_CNT。keeper与远端CLK异常下，仍可能输出错误PCM而没有明确故障标志。

## 误判

不能将内部WNS、仿真总线X检查、frozen或源文件中的引脚表等同于实板接口验收。首帧raw ID0、align ID1是现有管线语义，不应盲改编号。旧M6原始数字参考必须使用显式诊断配置，不能与生产启动门控混用。

## 根因

datapath_only屏蔽Hold且分段预算未自动组合往返外部路径；短等待小于50ms生产门控。frozen只看PCM是否恒定，没有电流/外部CLK/VDD反馈，另一只麦和电容保持可能掩盖缺麦。

## 修法

保留生产RTL及125ns采点，新增独立传播时钟/边沿窗口分析与负例。PS实际C源增加首帧有界等待；TB扩展keeper、CLK异常、边界、PS AXI三种重启；修正能力描述。只提出BRAM方案，不改已回归核心。

## 复现指纹

`scripts/validate_pdm_convergence.py`：63个RTL与基线/前轮manifest不变；完整SoC Setup最差+5.314ns、Hold+80.972ns；负例Setup−94.686ns、Hold−119.028ns。14功能、11启动/兼容、3AXI epoch/288字及C正常/无数据测试通过；修改前C顺序检查early_measure=1。BRAM111.5/140。

完整命令、实际报告与边界见[本轮报告](../PDM收敛性整改报告_2026-10-16.md)及[外部窗口说明](../pdm_external_window.md)，输出 `build/pdm_convergence/acceptance.json`。
