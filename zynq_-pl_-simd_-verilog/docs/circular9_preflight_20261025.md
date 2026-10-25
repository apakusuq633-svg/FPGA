# 9 麦受控实测预检

`pc/circular9_preflight.py` 只读检查板端接口、匹配发布包和操作者审核记录，分别判断可以开始哪一阶段的受控试验。它不下载 FPGA、不修改 RPM、不选择目标，也不启停 GSC。

当前实物事实：用户确认麦克风为 Infineon IM73D122，外圈 8 个声孔的圆半径为 **30 mm**，中心 1 麦，阵列竖放、声源位于正面半空间。用户已说明 H1 是原理图标注错误，实物接线正确；逐麦响应、通道相位和声孔坐标仍需实测，不能从网名推断。IM73D122 的 3.3 V、2.5 MHz 配置已按[官方数据手册](https://www.infineon.com/assets/row/public/documents/30/49/infineon-im73d122-datasheet-en.pdf)核对，但板上实际电压、时钟频率/占空比和连线质量尚不能由软件证明。

## 三种资格分别报告

| 输出 | 满足条件后可以做什么 | 不代表什么 |
|---|---|---|
| `capture-ready` | 在人工接线/电气/下载审核后，进行逐麦、原始录音和标定采集 | 不证明 9 颗麦独立对应、不证明方向准确、不证明模型有效 |
| `localization-ready` | 在上述基础上，执行带角度真值的方向试验 | 不代表三声源一定可分；分辨能力需实测 |
| `fault-diagnosis-ready` | 在上述基础上，执行已验证模型测试域内的故障诊断试验 | 不代表当前一定存在故障，也不代替独立音箱/设备真值 |

未标定、无真实诊断模型时，`capture-ready` 仍可通过，用于补齐这些实测数据；另外两项必须保持未通过。只具备正常基线的异常检测不能取得故障诊断资格。任何阶段通过都不把 `board_acceptance` 改成 true，完整板级验收仍需独立保存长时间连续性、角度误差、分离保真和识别统计。

## 1. 准备当前发布包和人工审核记录

使用根代理本轮重新构建的 `build/circular9_direction_release`。旧 ELF 缺少新增运行契约字段时，工具会拒绝，不用默认值补齐。

在工程根目录执行；以下 `python` 可替换为本机有效的 Python 3.9 以上解释器，本工作站为 `C:/msys64/ucrt64/bin/python.exe`。

```powershell
python pc/circular9_preflight.py --write-review-template measurements/review_run01.json
```

先建立 `measurements` 目录。模板中的已知型号和规格核对不会自动变成板上测量结果。按实物填写以下信息：

- `board_id`、`review_id`、带时区的 `reviewed_at`，例如 `2026-10-25T20:00:00+08:00`。
- `electrical`：实际供电电压、实际 PDM CLK 频率和占空比、独立 DATA_5 路径与 FPGA 扩展排针核对。IM73D122 数据手册允许 VDD 1.62～3.6 V，2.5 MHz 属高性能时钟区，≤3 MHz 时占空比 40～60%；工具按本工程目标额外要求实测 CLK 为 2.5 MHz±1%。模板未预填示波器或电压读数。
- `deployment`：实际下载的发布包 manifest、`pl.bit`、`ps_ui.elf` 的 SHA256，以及确已使用同一套文件的人工核对。哈希可用 PowerShell `Get-FileHash -Algorithm SHA256` 获取，填写小写十六进制。工具核对运行声明和包文件，不能远程读取并认证整个 PL/ELF 内存。
- `localization`：只有完成逐颗激励、声孔坐标测量和幅相标定后，才填写对应 true、非零标定版本及审核编号。首次录音允许保留 false。
- `diagnosis`：只有真实录音模型按独立原始录音分组完成验证后，才填写模型版本及验收编号；版本必须同时匹配包 `model_version` 和运行版本，验收编号必须精确匹配包 `model_review_id`，不能借用另一模型的非空编号。模型头/JSON 同样受包文件哈希检查。RPM 必须来自实际测量或可靠的机器设置，并记录来源。首次采集允许保留版本 0、空编号。

审核记录是操作者声明，必须有对应测量/下载记录支撑。更换硬件、连线、发布包、标定或模型后更新记录，不能直接沿用之前的 true。

## 2. 获取只读预检报告

PC 网口使用 192.168.2.20/24，板端默认 192.168.2.10。完成匹配包下载、PDM 冷启动和系统启动后，适度播放宽带声音，使各麦有活动且不削顶。首次诊断还需要完整稳定观察窗和 CPU1 处理时间；不能上电后立即拿不到候选就认定故障。

```powershell
python pc/circular9_preflight.py --package build/circular9_direction_release --url http://192.168.2.10 --review measurements/review_run01.json --output measurements/preflight_run01.json
```

默认读取 3 轮，每轮依次只读 `/api/status`、`/api/gsc`、`/api/candidates`、`/api/heatmap`，轮间隔 1 秒。报告保留原始 HTTP JSON 证据、每个门限及拒绝原因。每次使用新输出文件名，不覆盖上一轮记录。

主要核对项：

- 发布包中全部文件的长度和 SHA256；生产 ABI P9D2、C9F2/C9S3、9 路/10 槽/掩码 511、DECIM16、156250 Hz、1024 点窗/512 点 hop、36 麦对，以及本轮 30 mm 声孔圆半径。S3 加入实际协方差和多频带辅助搜索，旧 S2 诊断模型不能沿用；新增细角导向控制的配套 PL/PS 构建也须来自同一包。
- `/api/gsc` 声明的 ABI、RV32 ITCM 哈希和几何版本与包一致。几何版本是配置身份，不是实际几何测量证据。
- 音频块与麦克风快照序号确实前进，九路电平数组完整、无冻结、无削顶、探测期间无新增丢样/时钟错误。九路均有电平不能替代逐麦独立映射验收。
- 定位图完整、提交序号前进、年龄有效；多声源造成的单主峰歧义本身不会当成采集失败。
- 物理定位审核、运行 `geometry_confirmed`、`calibration_status=measured_reviewed`、非零标定版本一致，才能升级定位资格。
- PS 计时必须有新增样本且已观察最大值不超过 10000 µs；统计范围是首个对齐 PCM 到 PS 首次收到元数据，排除麦克风启动、声传播、浏览器显示和诊断窗。短预检不能替代完整负载持续测试。
- 诊断 RPM、模型验收、40000 点快照绑定、载频提取和 2200～4600 Hz 分离掩码完整性一致。候选过期、丢包后绑定改变、错误模型、缺失载频时不能声称有效故障方向。
- 故障模式中，没有唯一合格故障方向却连续两轮报告 GSC active，会拒绝。单轮跨端点瞬态会提示复测；工具没有物理转向回读能力。

默认退出码 0 仅表示当前在线 `capture-ready` 已满足；退出码 2 表示请求阶段未满足。需要强制某一更高阶段时：

```powershell
python pc/circular9_preflight.py --package build/circular9_direction_release --review measurements/review_run02.json --require-stage localization-ready --output measurements/preflight_run02.json
```

JSON 中每阶段有 `conditions_satisfied`、`ready_now`、`own_blockers` 和前序条件状态。不能只看退出码 0 就宣称全部通过。

## 3. 保存原始数据，再复核传输证据

使用现有接收工具，不把串口日志或浏览器图像当作原始九路音频：

```powershell
python pc/circular9_receive.py --packets-only --seconds 30 --output recordings/raw_run01
python pc/circular9_preflight.py --package build/circular9_direction_release --review measurements/review_run01.json --recording recordings/raw_run01 --output measurements/preflight_raw_run01.json
```

先只收原包可减少实时逐点 PCM/JSON 解码负载，实际持续吞吐和丢包仍需测量。需要 PCM 文件时再离线转换：

```powershell
python pc/circular9_receive.py --decode-capture recordings/raw_run01/packets.c9 --output recordings/raw_run01_decoded
```

预检重新解析 `packets.c9` 原包，验证 CRC/所有权、九路配置、单一 session/epoch、逐点序号连续、40 MHz 时间戳每点 256 tick、无上游/软件丢失、九路原始信号非恒值且无满量程削顶，并匹配本轮几何/标定版本。它不会静默拼接跨丢包片段。录音质量通过仍不证明空间映射正确；逐麦标定应采用对应的采集与标定工作流。

正常机器、故障机器和干扰音需要独立真值。先各音箱单独播放确认映射和录音，再同步播放三个声源；交换位置和音量，尤其验证故障源更小时是否仍被检出。标注特征与导出分离音频继续使用 `pc/circular9_dataset.py`，不能把方向图最大值当作故障标签。

## 4. 重放旧报告与离线软件自检

在线报告保存原始 `http_evidence`、选择的包 manifest 和人工审核记录/哈希。可以直接重放该报告，也可重放另存的 HTTP 证据对象：

```powershell
python pc/circular9_preflight.py --package build/circular9_direction_release --review measurements/review_run01.json --offline measurements/preflight_run01.json --output measurements/replayed_run01.json
python scripts/check_circular9_preflight.py
```

离线模式始终 `ready_now=false`，即使所有历史条件满足也不能取得当前实板资格；证据默认超过 300 秒则视为陈旧。离线测试使用明确标注为合成的包、人工审核和 HTTP/C9C2 夹具，结果位于 `build/circular9_preflight_checks/results.json`，不能当作板上验收数据。

## 软件不能补写的实测证据

当前仍需要实物产生：板上 VDD/CLK 波形、九颗麦逐一响应及相位/槽位顺序、实测声孔坐标和幅相标定、带真实角度的方向/分离录音、实际 RPM 来源、独立正常/故障/干扰数据及模型验证、运行真实网络/UI/GSC/CPU1 负载下的 PS 延时和持续丢样统计。IM73D122 型号与 H1 标注问题已由用户澄清，不再列为“型号未知/确定缺线”；也不能因为这两项澄清就虚构以上实测结果。
