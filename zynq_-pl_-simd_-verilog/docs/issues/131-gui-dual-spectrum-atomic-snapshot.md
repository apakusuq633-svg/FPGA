# 双谱快照修复：离线完成，未上板（2026-10-26）

## 本轮限制

本轮没有访问板卡HTTP/JTAG，没有烧录，没有变更现有发布包和`program_snapshot_repaired.ps1`。新程序单独保存在`build/gui_spectra_offline_20261026/ps_ui.elf`，不要把它视为已完成实板验收。

## 修复机制

1. 旧GUI需1次包络请求+8次音频分块请求；中途换帧会409，且即使数据完整，最新状态序号变化也会让GUI丢弃。新增`/api/gui/snapshot?sequence=N&index=I`，一次复制同一个CPU0持有结果的4096点音频和128组包络。固定8512字节，间隔256点服务DMA，不在HTTP中计算FFT/包络，不建立新采集链路。
2. GUI核对格式、编号、轨迹、采集session/epoch/起点、长度和有效性标志。完整收到的旧帧允许显示，但明确标为历史；不拼接不同快照。
3. 409至多刷新一次候选并重试一次；轨迹已消失则停止本次读取，等待下一次自动更新。只允许一份波形请求在途；用户切换轨迹会取消旧请求的显示。
4. 音频和包络有独立来源说明，初始等待、读取失败、输入无效、低载频能量、无明显调制均区分。默认最多每5秒自动读取。音频谱排除DC，首频点按真实Fs/4096标注。
5. 将原C9F2滤波/解析包络/抗混叠/Hann/FFT提取为不依赖RPM的共用分析段。仅已存在的“未知转速=0”任务允许计算Hz包络和实际RMS；18维阶次特征仍为未计算，分类仍UNKNOWN/BAD_INPUT，故障方向不确认。NaN、范围外转速或无效音频仍不放行。没有填入默认1500/1800rpm。
6. 有效转速的阶次峰提取和归一化仍使用同一算法。未改载频2200–4600Hz、包络900Hz范围、采样、定位、分离算法、几何标志或模型保护。

## 二进制协议

小端16个uint32头：magic=0x43394732、版本1、结果sequence、track、index、Fs分子78125、Fs分母2、音频点数4096、包络组数128、包络存在标志、提取状态、first_sample、epoch、session、该快照shaft_millihz（未知0）、阶次特征已计算标志。
随后4096个int16音频、128个uint16归一化包络（0..1000）。包络有效不表示分类有效；features_available也不表示故障标签已验证。

## 通过的离线验证

- GUI/API/健康/归档/诊断/降采样/几何检查全部通过，页面约51KiB，仍小于60000字节上限。
- 直接用C路由生成二进制，由JS解码、FFT并显示双谱，通过。数据为合成测试，非新实板数据。
- 验证409重试有界、错误轨迹、错误会话、短包、换轨迹取消、轮询换帧、单请求在途、自动读取与会话键、无包络状态及历史保留。
- 无RPM时包络存在而类别仍UNKNOWN，18维特征仍零且GUI标为未计算；相同音频的无RPM/有RPM导出包络一致。
- 对修改前归档版本，6组合成波形、10/25/30Hz，有效18维特征、提取元数据与全部2049个谱值逐bit一致。证据`checks/feature_equivalence.json`，比较99888字节，SHA256均为13de5c967c51823ee3d42f4ac2411ad1169571c0ef9229cdb712a6d8036c236b。
- 实际CPU0/CPU1管线宿主回归通过；Cortex-A9编译链接通过；BSS保持48601168字节。

## 修改文件

运行：`sw/circular9_envelope.h`、`sw/circular9_diagnosis.c`、`sw/ps_circular9_gui.h`、`sw/circular9_full_gui.js`、`sw/circular9_gui_complete.js`、`sw/ps_ui_page.h`、`profiles/full_gui9/page_template.html`。
测试：`sw/circular9_diagnosis_test.c`、`profiles/full_gui9/tests/api_test.c`、`profiles/full_gui9/tests/gui_test.js`、`profiles/full_gui9/check.py`、生成测试HTML。

## 仍需上板验证

未知RPM时现在每份候选也计算包络，增加真实CPU1工作量；增加多少、三候选是否仍满足3秒预算，均未实测。不能把宿主测试或编译通过当作实时性验收。未来上板先核对DMA错误/期限计数，再验证无RPM双谱、换帧/409、断流/恢复和多候选，不修改转速/模型保护来掩盖问题。

新固件未加载，因此当前板子和原烧录指令仍是之前版本。待用户同意上板后再建立独立加载包。
