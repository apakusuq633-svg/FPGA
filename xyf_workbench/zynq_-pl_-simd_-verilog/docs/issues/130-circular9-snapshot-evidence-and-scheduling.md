# 130：九麦诊断快照恢复（2026-10-26）

## 结果与边界

已在实板恢复“九路历史 → 辅助方向 → 轨迹 → CPU1分离诊断结构 → HTTP → 健康历史”的流水线。不是定位精度、轴承分类或多电机应用验收。当前几何未确认、标定版本0、模型版本0、转速未确认均保持；`loc_reason=36`仍然存在，未降低门限或强置定位有效。

最终加载ELF：`11705c5ef4d796569400c72de9de38f612bd1b8807509ba996db36fcbb511caa`。
PL bit：`f3ed316a9ea04e05de7d8d0ca211a22fc6f4f6ab368a15b997e82a22f06a2e72`，与修复前一致。RTL/XDC保护文件哈希核对一致。未综合、未写Flash；本记录完成时未推送远程。

## 逐阶段证据

所有证据位于 `build/snapshot_repair_20261026/`；每阶段有独立bit/ELF/清单/加载日志。`before/`保存修复前相关源码和哈希，包括当时已修改的GUI头文件。

- stage1：仅增加覆盖原因和时间统计。实测辅助结果常跨16384原始点，而每次证据只有8192点；接收年龄可达约154ms。真实稳定轨迹能累计观测，但覆盖不足；不是次数被固定为1。
- stage2：缓存固定几何地址和同一三次插值权重，保留double，保留参考分支。搜索最大约106ms降至约92ms，仍不能满足52ms证据节奏。
- stage3：尝试复指数递推，未见明确实测收益，最终撤回，不进入发布代码。
- stage4：用IFFT(X+iY)=x+iy同时得到两对实相关，复用对角根；不减麦对、不减频带、不减网格。辅助搜索最大约71ms，仍有跳步。
- stage5：采用原工程支持的16640点窗口，256预热+16384点真实证据，104.8576ms、7个重叠STFT；hop仍8192，200ms新鲜度不变。实板诊断开始启动并完成，但7次都被原512ms期限丢弃；处理约678ms、总耗时约779ms。证据：`stage5/live_fixed_source.json`。
- stage6：将计算/结果年龄预算与512ms调度hop分开，计算和结果年龄上限3000ms，输入排队年龄仍512ms。发布正式结果和音频。`stage6/live_sequence_verification.json`及历史接口记录。
- stage7：逐候选检查资格；非OBSERVED或覆盖不足的候选不再否决其他合格输出。每个输出仍满足原90%覆盖。记录未决方向数，存在被排除方向时不授予可信方向绑定，防止未解析干扰下输出已确认故障归因。多源分离算法/18维特征/分类器未改。

原先计划改为按证据终点挑诊断窗口，扩大真实窗口后实板已能提交，因此最终没有改动原有诊断窗口终点选择，减少变更范围。

## 最终实板结果

证据：`stage7/final_board_evidence.json`（UTC时间戳、ELF及实际HTTP数据），同版本连续记录 `stage7/live_sequence_verification.json` 中序号4→5，最终序号56。

- CPU1 started/completed=56/56；deadline_misses=0；snapshot_rejected=0；worker_coverage_rejected=0。
- processing_us_max=678562；queue_wait_us_max=100137；total_elapsed_us_max=778645。
- 原始DMA成功66923033帧；corrupt=0、drops=0、discontinuities=0。
- 当前候选1个，separation_ready=1；512点音频接口返回1024字节，峰值17 LSB；HTTP页面46777字节。
- 健康历史cursor=52；未知/无效结果仍能记录；事件0。不将历史条数与任务次数简单视为一一对应。
- 当前诊断bad_input，shaft_hz=0、model_version=0；包络envelope_valid=0。不是包络传输已验证，也不是正常机械状态。未伪造转速，未绕过模型、几何或分离门控。
- API中stale判断还包含转速和跟踪绑定，不单是年龄；较慢CPU1任务会打断辅助搜索并导致重建身份，当前仍不能宣称实时故障方向路由已经验收。
- 测试期间用户确认开始固定宽带音；较长后续记录不保证全程声源不变。真实多声源/多电机/单故障场景未验收。三候选能力由合成回归验证，不冒充实板多源结论。

## 测试

- `scripts/check_circular9_candidates.py`：多源、弱源、噪声、混响、离网格、协方差和载频保护通过。
- 优化与参考分支报告的方向/分数/支持输出8行完全一致；详见 `checks/reference_comparison.json`。不是所有浮点中间量逐bit相同。
- `scripts/check_circular9_snapshot_repair.py`：64000次插值等价测试最大绝对误差3.64e-12（测试输入尺度1e4）；32组双实数IFFT等价最大误差5.56e-17；缓存失效、按1/2/3hop回放、独立候选调度及未决方向可信归因拒绝均通过。全部为合成宿主测试。
- `scripts/check_circular9_aux.py`及实际CPU0/CPU1管线回归通过；轨迹62项通过。
- `profiles/full_gui9/check.py`：GUI/API/健康/SQLite/诊断/降采样/几何通过。
- 实板JSON回放到mock DOM，正确显示非零快照；浏览器目视自动化超时，未声称完成真实浏览器视觉验收。
- Cortex-A9编译链接通过；搜索栈约16032字节，低于本工程64KiB CPU栈；未新增依赖。

## 修改文件

运行代码：`sw/circular9_candidates.c`、`sw/circular9_tracking.h`、`sw/circular9_schedule.h`、`sw/ps_circular9_aux.h`、`sw/ps_circular9_tasks.h`、`sw/ps_circular9_api.h`。
测试/工具：`sw/circular9_pipeline_test.c`、`sw/circular9_search_cache_test.c`、`sw/circular9_snapshot_schedule_test.c`、`scripts/check_circular9_pipeline.py`、`scripts/check_circular9_aux.py`、`scripts/check_circular9_snapshot_repair.py`、`scripts/package_snapshot_repair.py`、GUI实板数据回放测试。

## 加载与回退

新指令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\RISC-V\pipeline_latest4\zynq_-pl_-simd_-verilog\profiles\full_gui9\program_snapshot_repaired.ps1" -Program -OpenPage
```

不带`-Program`只校验，不访问板卡。新包在`build/snapshot_repair_20261026/release`。旧`build/gui9_complete_release`和`build/full_gui9_release`保留，可使用各自program.ps1回退；回退会恢复旧行为，RAM历史会随重新加载清除。

## 后续需真实条件的验收

需实际转速、匹配且验证过的C9F2模型、阵列几何/校准证据，才能验收分类和包络。还需多台同时运行、强弱源、移动/消失、三候选最坏耗时及长时压力测试。当前GUI刷新频率不等于诊断输出频率，512ms hop不代表能以2Hz完成诊断。


## 后续GUI双谱修正

快照存在时音频谱原来仍默认手动读取，新序号又清空曲线，因此页面会长期等待。已改为默认最多每5秒读取同快照音频，并保留、标注上次成功读取的历史曲线。包络未计算时明确提示真实转速未确认，不伪造包络。数值/算法/几何门控未改。

新PS ELF：48ff4e672bb85c727cc37fbd9c33226db6c7c8ac5f70db4ea7659c64277b4d8c；独立包 `build/snapshot_repair_20261026/gui_spectra`，已加载；上面的稳定加载入口已指向此包。原release和stage7保留。新GUI/API/历史曲线保留回归通过，HTTP新页面默认自动开关验证通过；未声称真实浏览器视觉验收。
