# 九麦高速采集与离线解码

首轮实测推荐在线仅保存原始协议包，采完后再生成逐采样 JSON 与 PCM。当前每通道采样率为 156250 Hz，在线写 156250 行/秒 JSON 会额外占用 PC 的 CPU 与磁盘。本工具不改变 FPGA/PS 采样、滤波、定位或诊断。

用户最新确认外圈声孔圆半径为 30 mm、实物 H1 信号线正确、麦克风为 Infineon IM73D122；官方规格已核对支持工程的 3.3 V 与 2.5 MHz，仍需板上波形验收。原始包采集可供九路独立验证和后续标定，但收到数据不等于通道、几何、角度或故障模型已经验收。

## 推荐首轮采集

在工程根目录运行，输出目录必须是新目录：

```powershell
& C:/msys64/ucrt64/bin/python.exe pc/circular9_receive.py --packets-only --seconds 30 --output recordings/nine_mic_run01
```

默认监听 `0.0.0.0:1234`，可用 `--bind`、`--port` 修改。PS 发往的 PC 地址仍需与实际网卡一致。快速模式写出：

- `packets.c9`：未经重采样、未经 PCM 重新打包的原始 UDP 负载，按旧格式 `uint32 小端长度 + 原始包` 保存；以 256 KiB 有界缓存批量落盘。
- `manifest.json`：CRC/协议有效包、非法包、样本、丢包/重复/乱序、分段、实际 socket 接收缓冲及原始捕获 SHA-256。
- `events.jsonl`：不连续原因，最多记录前 1024 次事件；后续事件累计计数，避免错误流重新变成高速 JSON 写入。

快速模式不生成 `frames.jsonl` 和逐段 PCM，不解包九路 PCM 为逐样本字典；仍校验完整外层 CRC、每槽 CRC/所有权、版本、采样率和 GSC 旁路状态。协议支持每包 1～8 个样本，最大 C9C2 长度 1124 字节。

按满 8 样本/包估算，UDP 负载约 **21.95 MB/s**，30 秒捕获文件约 **661 MB**；网卡、链路和磁盘必须实测能持续承担这一流量。100 Mbit/s 链路无法无损承载这个协议的满速流量。快速保存减少 PC 工作量，不会自动提高开发板发包能力或证明网路无丢包。

## 采完后离线转换

```powershell
& C:/msys64/ucrt64/bin/python.exe pc/circular9_receive.py --decode-capture recordings/nine_mic_run01/packets.c9 --output recordings/nine_mic_run01_decoded
```

离线模式不打开 UDP socket。它使用同一个协议解码器，输出原有格式：

- `segment0000_raw9.pcm`：九路交织 signed-int16 小端，每帧 18 字节，采样率准确为 156250/1 Hz。
- `segment0000_fir.pcm`、`segment0000_gsc.pcm`：对应 FIR 和 GSC 输出，signed-int16 小端。
- `frames.jsonl`：每个样本的时间戳、方向版本、epoch、可信状态、丢样计数及分段号。
- `manifest.json`、`events.jsonl`：完整性与分段统计；完整转换还记录原始捕获文件 SHA-256。

会话、包序号、采样序号、时间戳、epoch、几何/标定版本或丢样计数不连续会开始新段。被 CRC/所有权检查拒绝的包也会强制切段，即使后续样本编号看起来连续，也不会将两侧悄悄拼接。计数正常 32 位回绕不会被误判为丢包。

如果捕获末尾只有半个长度或半个包，或者长度超出 UDP 上限，工具明确报错并保留 `completed=false` 的部分转换清单；不会猜测下一个包的起点。边界内的非法 C9C2 数据报被计为非法包，保留在原始捕获中，转换时跳过并切段。

## 兼容已有使用方式

不加新参数仍会在线同时保存原始包、PCM 和逐样本 JSON：

```powershell
& C:/msys64/ucrt64/bin/python.exe pc/circular9_receive.py --seconds 30 --output recordings/nine_mic_full_run01
```

既有 `decode(data)` 接口和 `packets.c9` 长度前缀格式保持兼容。新共享模块 `pc/circular9_capture.py` 必须和入口脚本一起保留。

## 软件验证

```powershell
& C:/msys64/ucrt64/bin/python.exe scripts/check_circular9_receive.py
```

检查包含原 C 协议写入夹具和 332 个逐字节破坏反例、伪造外层 CRC 后的内层 CRC/所有权检查、快速/默认/离线 PCM 与元数据逐字节一致、丢包/乱序/版本变化切段、正常回绕、断包/超大长度、有界事件记录，以及真实本机 UDP 回环的入口测试。

本机小规模落盘测试的快速模式约可处理 60 万样本/秒，完整解码约 15 万样本/秒；准确数值保存在 `build/circular9_receive_checks/results.json`。这只是本机协议验证和落盘结果，不是实际板卡、网卡或长时间持续采集的验收。正式采集应检查 `invalid_packets`、`missing_packets`、`missing_samples`、`segments`，并保留源包供复查。
