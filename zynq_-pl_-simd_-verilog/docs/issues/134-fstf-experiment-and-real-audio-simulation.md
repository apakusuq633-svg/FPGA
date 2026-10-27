# FSTF六类实验接入与九路端到端模拟（2026-10-27）

## 最重要结论

1. 已完成独立六类实验适配层，API与GUI可显示实验细类；启用/关闭两种A9构建通过。原ABI2三类模型、18维C9F2特征与可信故障门控不变。
2. 已运行9个真实FSTF录音驱动的九路PCM模拟场景。机制/安全回归通过，**应用验收未通过**：六个单源场景仅4个细类正确，三个自动双源场景均未完整诊断两个方向。
3. 给定真实方向的独立下游对照中，三个双源场景都能完成分离并正确得到正常/内圈或正常/滚动体实验细类。它们不是自动定位成功；说明当前自动多源搜索/轨迹覆盖仍是主要阻碍。
4. 连续调度暴露并修复了快照时间无符号下溢；用同一模拟PCM和旧任务头隔离复现，旧版最后快照sequence3/count0，新版sequence3/count1。这不是重新证明实板已修好。

## 一、模型接入设计

复用先前训练的标准化最近中心模型（验证集与64树森林同为5/7，事先保留简单基线，不根据此次测试重新选模型）。参数复制到sw/fstf_c9f2_experimental_model.h。
构建脚本新增-FstfExperimental，只允许九麦live模式；默认不启用。用C9_FSTF_EXPERIMENTAL=1编译时才计算六类距离。
新增字段独立于原label/provisional_label：fstf_available/class/version/distance/margin。API提供fstf_experiment_enabled和diagnosis.fstf_experimental，validated恒0。GUI显示“FSTF实验细类（未验证）”，距离/间隔不是概率。
只有C9F2、非零track_id、合法网格、稳定/分离/快照绑定、有效分离mask、40000点、有效一次特征FFT、1800rpm且未削顶的输入才显示实验细类。缺少确认转速仍等待，不能用默认25Hz或测试音调制频率代替。
实验输出不写入原可信label、不触发fault_direction_valid、不参与故障方向控制与可信报警。没有虚构模型验证、几何标定、分离滤波掩码验证。
模型给的是临时最近类，不是已校准拒识器。特别是外圈误判正常，不能用于设备健康结论。实验细类当前在诊断快照/API/GUI及其JSON导出中，未冒充已验证事件记录。

## 二、模拟范围

源文件来自用户指定六个FSTF 1800rpm WAV，每个源绑定路径与SHA256。每个场景2.56s，PCM156250Hz，400000原始点；源WAV48kHz通过FFT带限重采样并施加物理通道位置对应的远场传播相位，九路量化为int16。坐标继承X22/Y25.5/斜向23mm暂按45度。
每8192原始点推进一次，运行16640点实际辅助搜索、真实轨迹更新、DDR历史、512ms诊断调度、真实C9S3分离、C9F2提取、实验分类、快照发布和真实c9_candidates_json序列化。未把真值方向注入这条自动路径。
宿主clock/cache/MMIO为明确的模拟替身，不仿真PDM/CIC/PL FFT/RV32。生产geometry/calibration标志未改；宿主fixture为隔离软件机制使用显式测试标定宏，JSON写入HOST_FSTF_PLANE_WAVE_SIMULATION来源，不能视为物理校准证据。
混合RMS为显式模拟增益：等强双源各0.04，强正常/弱滚动体0.08/0.02，噪声RMS0.00003；无房间脉冲响应、手机扬声器响应、真实麦克风误差或A9占空比仿真。
内圈/滚动体从15.36秒开始，其余较长录音从7.168秒开始，处于同录音留出后段；不是独立录制。外圈只有2秒，循环填充2.56秒，标记训练重叠，绝不能算独立测试准确率。

## 三、最终结果（连续调度版）

|场景|自动快照末序号|自动链路最终输出|结论|
|---|---:|---|---|
|内圈单源|3|内圈，约−2.81度|实验细类正确|
|外圈单源|3|正常，约+2.81度|错误，且外圈无独立测试数据|
|滚动体单源|3|滚动体，约−2.81度|实验细类正确|
|正常单源|3|正常，约+2.81度|实验细类正确|
|松动单源|3|滚动体，约−2.81度|错误|
|复合单源|3|复合，约−2.81度|实验细类正确|
|正常−50度/内圈+50度|2|仅正常方向历史快照，当前已过期|缺少故障方向，未通过|
|内圈−50度/正常+50度|2|仅正常方向历史快照，当前已过期|左右互换仍未通过|
|强正常−50度/弱滚动体+50度|3|仅正常方向当前快照|漏掉弱故障方向，未通过|

以上所有可信label仍unknown，fault_direction_valid为0；“正确”只指实验细类与这段模拟源文件标签相符。

### 已知方向隔离对照

单独将真值方向传给分离器（与自动结果分开保存）：三组双源ready_mask均为3，输出依次healthy/inner、inner/healthy、healthy/ball。该对照仅定位下游瓶颈，不用来填写自动候选，也不计入自动端到端通过率。

## 四、连续快照错误与最小修复

c9_diagnostic_due保持旧hop相位，有时选择稍早窗口终点selected；更新的轨迹map_sample可比它晚几毫秒。旧worker使用(uint32_t)(snapshot_end-map_sample)<=31250，出现负差下溢，完成后变为count0/rejection1。
新增c9_snapshot_map_time_valid：map不能晚于captured_end；相对于snapshot_end的有符号年龄不能超过31250点。随后仍重新检查每条轨迹真实覆盖所选完整窗口；没有降低90%覆盖或扩大输入队列期限。
增加新观测、真实未来观测拒绝、200ms边界、过期拒绝及32位回绕测试。完整旧任务头对照结果保存在timestamp_before_after.json及before_timestamp_single_inner.json。对照使用当前一致数据结构，仅替换保存的旧任务头，不冒称完整旧bitstream实测。

## 五、修改与验证

核心文件：sw/circular9_diagnosis.[ch]、sw/fstf_c9f2_experimental_model.h、sw/ps_circular9_api.h、sw/circular9_full_gui.js、sw/ps_ui_page.h、scripts/build_ui_pipeline.ps1。
时间修复：sw/circular9_schedule.h、sw/ps_circular9_tasks.h、sw/circular9_snapshot_schedule_test.c。
测试：sw/circular9_fstf_adapter_test.c、sw/circular9_fstf_e2e_test.c、scripts/run_fstf_c9_e2e.py、scripts/check_fstf_c9_experiment.py、profiles/full_gui9/tests/gui_test.js。
实验启用/关闭、六类分数空间映射、10种无效输入拒绝、真实C JSON到模拟浏览器DOM、原诊断/健康/归档/几何/降采样/管线/跟踪/快照回归通过。Cortex-A9两模式构建通过。
应用验收明确false，不把测试脚本退出0解释成多电机目标达成。未上板；所有API中的宿主模拟微秒计数都是虚拟时钟，不是实际A9性能。

一键复现：用既有Python运行scripts/check_fstf_c9_experiment.py。脚本每次重新编译宿主入口，不复用旧exe；结果在build/fstf_integration_20261027/verification.json与e2e_results.json。9个连续PCM文件、API结果、分离音频及源参数均保留，后续改搜索可直接做固定数据回归，不需重新播放手机。

## 六、下一步

优先利用三组双源失败案例逐窗跟踪频带峰、轨迹ID/锚点/支持区间，修复故障源不能稳定覆盖的问题；不要进一步降低90%或修改类别来掩盖漏检。
外圈与松动需要补独立数据和播放回采验证；同原录音的切片或循环不能解决泛化缺口。现有已知方向对照表明有可用下游通路，但不证明真实房间、多源、模型正常误报率合格。

## 七、上板产物（本轮未执行）

最新入口指向独立实验包gui_fstf_experimental_20261027。旧多峰包保留。
新程序默认不自动确认转速；以后播放对应FSTF音频时，需在GUI输入1800rpm并确认，同session/epoch才生效。其他测试音不要确认1800rpm。
实验关闭包gui_fstf_disabled_20261027包含同一次快照时间修复、相同GUI，但不计算六类实验预测。
最新命令仅供以后使用：
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\RISC-V\pipeline_latest4\zynq_-pl_-simd_-verilog\profiles\full_gui9\program_latest.ps1" -Program -OpenPage
关闭实验：把入口换为build/gui_fstf_disabled_20261027/program.ps1。

RTL/XDC/bitstream与上版相同，不需要新Vivado实现；没有把旧时序报告当成新PS性能结果。本记录完成时未提交或推送Git。
