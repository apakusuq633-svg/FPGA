# 同步原始多通道快照与校准

8麦及12麦候选GUI的“下载同步原始快照”保存1024个采样时刻，采样率为78125/2=39062.5Hz，窗口26.2144ms。它来自去波束相加之前的同步采集缓存；每路是PCM24截去低8位后的有符号int16，不是PDM位流。音频DAS/FIR继续运行，定位计算在快照复制期间暂时暂停，网页显示“校准快照暂停”。

RV32冻结两bank并发布请求号/第一样点/序号。PS每轮最多读取32个打包字，拷贝到独立缓冲后归还；浏览器传输从PS缓冲读取。请求号、发布状态和相邻bank序号均检查，过期/取消不会发布混合快照。GUI原始接口不自动修改增益、延时或坐标。

`GET /api/raw/start`返回202及请求号；忙或固件不支持返回409。`GET /api/raw`等待返回202，完成返回application/octet-stream，失败返回409。PC入口：

```powershell
python scripts/analyze_raw_capture.py --url http://192.168.2.10 --output build/calibration
python scripts/analyze_raw_capture.py --input microphones.raw --output build/calibration
```

文件前64字节为16个小端uint32：magic=0x52415701、header_bytes=64、请求号、通道数、帧数、fs_num、fs_den、first_sample、首bank序号、sample_bits=16、后6字保留0。其后为frame-major小端int16：一个采样时刻的所有通道连续排列，总文件大小64+1024×channels×2。第一样点为PL采集的32位计数，需按会话及回绕处理，不能与目前PS音频流的相对起点直接相减。

分析器保存原始文件、npz和json，输出各路DC、去均值RMS、峰值、clip及相对GCC时差。已知声源XYZ与真实阵列坐标同时提供后，才可从观测时差减去几何预测，得到候选通道固定延时。普通声音的观测时差包含声源方向，不能直接作为校准偏差。12麦坐标尚未确定，工具拒绝伪造几何。

校准在多个已知声源位置、多个频带重复，检查通道顺序、接L/R边沿、时差残差是否固定以及频响/增益是否一致。1024点适合通路/相位检查；稳定频响和混响评估需要重复快照或后续连续多路录音，不能把单个短窗当成房间声学验收。

本轮数字验收含8/12/16路宿主拷贝、超时、请求切换、序号回绕和8/12麦真实RV32固件SoC导出；尚未下载并测量真实阵列。
