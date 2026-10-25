# 九麦完整GUI集成（2026-10-25）

保留 `pipeline_latest4` 九麦PL、RV32、DMA、C9S3分离、C9F2诊断和模型保护，迁入 `pipeline_latest2` 的完整监测界面风格与功能。不是八麦48k版本，也不是旧九麦25mm近场版本。生产配置仍为PDM 2.5MHz、原始PCM 156250Hz、诊断39062.5Hz、30mm圆环加中心、前半球方向搜索。

## 上板与历史归档

```powershell
# 默认只校验文件，不连接板卡。
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\RISC-V\pipeline_latest4\zynq_-pl_-simd_-verilog\profiles\full_gui9\program.ps1"
# 显式加载配套bit/ELF/init，打开192.168.2.10。
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\RISC-V\pipeline_latest4\zynq_-pl_-simd_-verilog\profiles\full_gui9\program.ps1" -Program -OpenPage
# 可选PC SQLite持久归档，打开127.0.0.1:8769查看同一完整GUI。
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\RISC-V\pipeline_latest4\zynq_-pl_-simd_-verilog\profiles\full_gui9\start_archive.ps1"
```

JTAG加载易失，不写Flash；板卡供电、JTAG、PS网口需接好，电脑网口应为192.168.2.20/24。本次开发没有自动连接、复位或烧录板卡。

## 界面和数据来源

- 方向热图：原`/api/heatmap`，水平角/俯仰角，无距离扫描；最多5秒候选留痕。热图轮询目标10Hz，候选/通道状态2Hz，健康监测与运行指标1Hz；实际刷新受链路限制，串行请求不会叠加。
- 候选与诊断：原`/api/candidates`；按轨迹展示，不把声学轨迹当作机器身份。不配置真实模型时保持未知，不套用八麦旧四分类模型或票数。
- 选中轨迹波形：点击“获取同快照波形”。音频谱使用该快照前4096点，由浏览器去均值/Hann/FFT；包络谱只复制CPU1已计算的C9F2 FFT，0–900Hz分组最大值，排除DC。两者独立峰值归一；轨迹/序号改变或HTTP409即清除/拒绝混合快照。包络载频仍2200–4600Hz，算法未改成旧1400–4600Hz。
- 双麦调试：CPU0分64点片段读取现有历史，片段之间服务实时音频。1024点同帧原始PCM，保留时延，不移位、不反相。浏览器计算AC相关系数及GCC正峰/负谷/绝对峰；搜索范围随156250Hz及名义30mm几何计算，不能直接认作真实声学TDOA。可手动单帧、连续10帧、导出JSON或下载九路同步原始快照。
- 九路原始下载：`/api/debug/raw`，32字节小端头（8个uint32：C9R1=0x43395231、Fs、点数、通道数、保留、起点、epoch、session），后接1024×9交错int16。双路接口C9P1头第4/5字为通道A/B，后接1024×2 int16。读取不会停止或重新配置PL。
- 固定表格列宽与等宽数字，保留系统快照、通道电平、RMS、频谱轴、事件详情与导出。

## 监测与事件

`circular9_health.h`为CPU0固定容量监测器：按轨迹、采集session和epoch分别累计。只读取现有诊断，不重复分类；模型有效、结果新鲜、转速有效且绑定匹配才计为有效诊断。连续3次异常进入疑似、5次进入报警、10次有效正常恢复关闭；恢复期再次异常返回报警。未知、干扰、断流不作为正常恢复。`anomaly`仅为异常报警，不能标成已确认机械故障。

板内256条趋势、32事件、8轨迹槽；满容量覆盖已关闭事件，未关闭报警不被静默覆盖，溢出计数显示在API。每条记录包含PS运行毫秒、诊断/采集标识、角度、真实RMS、标签、模型和状态。没有RTC，不将运行时间当作绝对发生时间。事件保存首次、确认、恢复观察、关闭时间；离线未关闭事件不被自动标成已恢复。

板上重启会清RAM。可选PC标准库SQLite在`%LOCALAPPDATA%\AcousticHealth9\health.sqlite3`保存跨重启历史，按绑定会话及ID去重，保留最多100000记录和5000事件。PC接收UTC单独保存，不能等同声源发生UTC。写盘和查询只在PC执行；网络或写盘错误不反馈中断PS。服务只监听127.0.0.1。完整GUI的“查看PC归档”可查询1/5/30分钟内历史，较多记录抽取真实记录展示，历史事件可看详情。

“启用/关闭监测”只关闭新增记录和报警累积，保留旧报警；浏览器暂停/关闭不影响PS监测。板内日志无磁盘写入。

## 修改范围与性能边界

新增 `sw/circular9_health.h`、`sw/ps_circular9_gui.h`、可读的 `sw/circular9_full_gui.js`。`ps_ui.c`只增加初始化、后台接入和路由；`ps_ui_page.h`替换内嵌页面，HTTP正文容量61440字节，保持原16位传输长度上限以内。`ps_circular9_tasks.h`每个结果增加三路128点包络显示副本。`circular9_diagnosis.c/.h`仅新增既有FFT压缩导出，不修改特征、模型或分类结果。`build_ui_pipeline.ps1`补本机PowerShell哈希兼容。原文件备份在`build/gui9_original`。

RTL/XDC本轮无修改。RV32镜像重新用本机编译器生成，因此生成头可能有差异，配套镜像和LUT随新ELF一起发布；没有沿用旧发布包。新位流、XSA、BSP、PS ELF必须配套。

新增监测结构宿主`sizeof=29208`字节，双路调试暂存18432字节，两个跨核结果共增加约1560字节。HTTP正文及连接缓冲也随容量增加，最终ARM ELF的资源见交付报告。新增包络压缩耗时仍纳入原CPU1截止期统计；没有改现有512ms截止期。CPU占用、网络并发和板上定位/诊断延迟尚未实测。

## 验证

`python profiles/full_gui9/check.py`执行针对性C状态机/API、C字符串页面还原、浏览器DOM/原始GCC范围、SQLite重启去重/故障隔离、原诊断回归。浏览器测试明确使用离线模拟输入，不是现场测量。新增显示不调用第二套PS诊断算法；未重复整套定位/采样扫描。

真实板仍需确认：页面连续刷新与长时间不丢样；候选与图谱序号一致；多声源分离；实际模型/标定；原PS截止期与新增监测开关对照；PC归档断线重连；真实故障触发/恢复。几何、标定、模型及转速保护均未绕过。
