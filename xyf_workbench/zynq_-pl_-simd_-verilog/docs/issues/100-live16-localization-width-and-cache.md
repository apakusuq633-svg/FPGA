# 100：16 麦定位计数、地址与转向循环扩容

> 本档案的7轮/75564点/第三轮锁定记录属于防漂移修改前版本。当前默认配置与新固件验收见[104](104-live16-default-srp-profile.md)、[105](105-capture-index-synchronous-read.md)及[16麦配置](../live16_localization.md)；不能复用旧日志认证本次新固件。

状态：已修并通过数字仿真与实现复核。参考模型、扫描/转向RTL、完整SoC、PS/GUI和40MHz布局布线已通过；生产固件连续7轮定位正确、第三轮自行锁定，全部16路延迟收敛，75564个连续音频样点与256个稳定增强样点通过、末尾丢样0，最终配套清单通过。真实16麦阵列尚未到位；定位频率尚未达到20～50Hz目标。

## 症状

16 麦固定方向 DAS 已通，但 SRP 仍例化4对、256格。把参数直接改为120对、1024格后，现有麦对计数和 LUT 地址不能覆盖全范围；转向几何循环与比较逻辑也只覆盖前8路。

## 误判

不能因为顶层 PCM 和 DAS 已扩到16路，就认为定位与自动转向也支持16路；固定方向配置未实际使用转向模块，原来的限制不会在第一阶段音频测试中暴露。扩网格还会暴露迟滞函数的4位轴差和状态中8位网格编号限制。

## 根因

SRP pair_q 为5位、窗口索引15位，分别不够120对和122880条 LUT。相关索引与网格索引共用 IDX_W，无法同时表达32点相关环与1024网格。几何模块麦编号3位，最大落差及变化检测写死8路。逐麦对重算FFT没有频谱复用；完整16路频谱32832B超过原DTCM容量。

## 修法

独立扩展 pair/窗口/相关/网格位宽；配置开关保留旧ABI。转向循环改为通道参数位宽、通道变化归约、平衡最大值树及5位轴差。新增0x10000的64KB数据缓存，排除原DTCM请求，原MMIO保持；FFT每通道仅计算一次，120对读取缓存。相关只保留−16..15的短环，负滞后从1024点序列尾部复制。SRP和转向LUT符号分别遵循相关滞后与补偿延迟定义。

PS使用独立16麦定位结果序号90/91，避免覆盖统计区；匹配位流版本后装载120对扫描LUT与16路转向LUT。GUI支持32×32最新点和轨迹，保留独立音频与定位的关联限制。

## 复现指纹

`python scripts/build_live16.py`、`python scripts/check_live16_model.py`、`python scripts/check_live16_localization.py`。

`LIVE16_LOCATION_PASS pairs=120 grid=1024 r_len=32 microphones=16`，两个场景全部1024评分等于参考；CH15独立改变必须同时触发更新和非零步长。原4对、8路转向回归也必须通过。完整SoC需 `LIVE16_SOC_PASS`，位流需 `FLOW_PASS` 和最终时序非负，打包需 `LIVE16_PACKAGE_PASS`；尚未通过的检查不得作为已完成。

本次Icarus指纹：`LIVE16_SOC_LOCATION_PASS grid=773 compute_cycles=9968351 total_cycles=11015972 snapshot_first=0`；`LIVE16_SOC_PASS samples=11014 steered_samples=256 drops=0 all_1024_scores_match=1`。SoC仅首个定位运行真实固件，后续256点使用测试端重复提交目标；完整迟滞另由模块TB覆盖。40MHz WNS+0.164ns、WHS+0.022ns。周期数折算首帧275.399ms，不能宣称20～50Hz。

2026-10-13 从复位完整重跑生产策略：`LIVE16_NATURAL_PASS frames=7 samples=75564 steered_samples=43288 settled_samples=256 drops=0`，入口 `check_live16_xsim.ps1 -Natural`，日志 `build/das16_loc/xsim_natural/simulation.log`；全部16路最终补偿匹配独立几何参考，`LIVE16_PACKAGE_PASS`。第2～7轮周期按40MHz折算约3.63Hz，真实声学验证和刷新率优化仍待完成。
