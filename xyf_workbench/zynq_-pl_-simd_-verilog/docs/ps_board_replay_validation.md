# PS 回放上板记录

2026-10-11，Zynq-7020，现有 PL 位流，`build/ui_pipeline_replay/ui.elf`。通过 JTAG 下载并运行，UART0 COM7 115200 8N1，PC 192.168.2.20，板卡 192.168.2.10。

两个 A9 核均识别成功，串口启动和分类正常；网口协商为 1000 Mbps，HTTP 首页返回 7212 字节，状态 JSON 包含完整音频段元数据和各 128 点的音频频谱、包络谱。CPU1 诊断及图谱计算耗时显示 162 ms，输入段为 40000 点，名义时长 1.024 秒。回放分类为 inner，票数 [3,1,96,0]；这只是合成测试结果。

第一轮连续监测约 44.36 秒，推进 43 段，耗时始终 162 ms，源丢样、PS 丢样与断续计数无增量。发现回放时间起点早于阻塞的 PHY 初始化，造成启动时跳过约 4 秒样点，已将回放起点移至网络初始化完成后。

修复后重新下载，连续监测约 34.03 秒，推进 34 段，耗时仍为 162 ms，源丢样、PS 丢样与断续计数无增量。原始记录：`build/ui_replay_board_uart_20261011.log`、`build/ui_replay_board_uart_fixed_20261011.log`、`build/ui_board_monitor.json`、`build/ui_board_monitor_fixed.json`。当前留在板上的是修复后的回放程序。

## 动态图谱验证

另行构建 `scripts/build_ui_pipeline.ps1 -DynamicReplay` 并下载后，采用两种调幅合成信号交替回放：载频 2 kHz、包络 100 Hz；载频 4 kHz、包络 200 Hz。每四个 40000 点段切换，即名义 4.096 秒。它只用于动态响应检查，分类结果没有真实故障含义。

`scripts/check_ui_dynamic_board.ps1` 连续检查约 24 秒，33 次状态读取覆盖帧 22 至 45。音频谱最大分组随场景在 13/26 之间切换，包络峰在 bin 21/42 之间切换，符合 FFT 分辨率；诊断耗时 162 ms，源及 PS 丢样均为 0。原始状态保存于 `build/ui_board_dynamic.json`。当前板上保留动态回放程序；默认不加 DynamicReplay 构建仍为固定回放。

复测命令：

```powershell
powershell -File scripts/monitor_ui_board.ps1 -Seconds 45 -Output build/ui_board_next.json
```

监测中的 audio_timeline_rate_hz 由离散诊断段首样点与 PC 请求时刻计算，存在约一段量化误差，不可用作 ADC 或 PL 实测采样率。当前没有启用真实 DAS 音频窗口，也未验证真实定位、真实增强和真实故障准确率。页面浏览器显示待用户确认，长期稳定性和真实模式仍待验收。
