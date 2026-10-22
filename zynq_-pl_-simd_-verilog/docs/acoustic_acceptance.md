# DAS/FIR 正式验收（2026-10-11）

本页取代旧版“GSC 必须通过”要求。生产目标为八通道 PDM → 对齐/直流阻断 → 连续 DAS → 32 抽头固定 FIR；GSC/NLMS 不参与生产构建，VUPD 动态执行次数必须为零。旧 GSC 源码与测试只保留作历史对照。

## 一次验收
在 WSL 中，从工程目录运行：

```bash
bash scripts/test_das_release.sh
```

它构建两套独立镜像，执行基础 RTL 回归、独立模型比较、PDM 引脚一致性检查、连续流测试和正式声学验收。通过标志为 `DAS_RELEASE_SIM_PASS`。不得用 LED、静态指令计数或空输入代替声学验收。

验收固件 `fw_main.c` 用确定性场景对照 FFT/GCC/SRP/DAS/FIR；生产固件 `fw_live.c` 读取真实 PDM 采集窗口的两个连续 512 样点 bank，计算四对 GCC-PHAT、4×256 SRP，并驱动转向块。定位使用周期快照，定位计算期间连续 DAS/FIR 不暂停；不声称原始采集窗口无间隙。

## 硬件边界
- 基线：8 通道，40 MHz，PCM 39.0625 kHz，每样点 1024 拍。
- 连续 FIR 复用原有 `u_vec_unit` 八路 SIMD-MAC，使用 W1/XP3；验收固件使用 W0。不是另建 MAC 阵列。
- DAS 每通道 64 样点历史，Q16 延迟量化到 1/16 样点，最大 62+15/16 样点。延迟来自真实转向寄存器，向量边界原子更新；忙或未锁定时保持最近有效延迟。
- 固定 FIR：32 抽头、Q15、10 kHz 低通。独立响应模型测得 200–8000 Hz 纹波 0.058806 dB，12 kHz 起阻带衰减 46.407149 dB。它是带限滤波，不是自适应干扰抵消或完整 CIC 补偿。
- SIMD 仲裁允许 CPU 标量/FFT 继续执行；CPU 向量操作与音频共享单元。即使 CPU 被 halt，音频仍可运行，因此音频占用时禁止 PS 改写系数。
- FIFO 满、非法延迟、空 FIFO 读取等均可观测，不得以静默丢样作为成功。

## 新寄存器
PS AXI 基址为 `0x43C00000`；下表偏移均相对基址。

| 偏移 | 名称 | 定义 |
|---|---|---|
| 0x380 | CTRL | bit0 使能，bit2 自动转向；bit1 清零只允许新会话未收样且停机空闲 |
| 0x384 | STATUS | bit0 忙，bit1 锁定，bit2 错误；bits11:3 FIFO 占用 |
| 0x388 | OUTPUTS | 成功输出样点数 |
| 0x38C | DATA | 读取并弹出一条；低16位 DAS，高16位 FIR，均有符号 |
| 0x390 | DROPS | 丢样计数 |
| 0x394 | MAX_CYCLES | 最大样点处理拍数 |
| 0x398 | ACCEPTED | 接受样点数 |
| 0x39C | VERSION | 0x44415301 |
| 0x3A0–0x3BC | DELAY0–7 | 手动 Q16 延迟 |

原始采集 PS 窗口仍为 0x300–0x37F；新增 RV32 核内镜像为 0xC000。生产固件拥有原始采集 bank，运行时 PS 不得争抢其读指针/释放操作；PS 只消费独立音频 FIFO。开始新 FIR 会话必须复位 SoC，避免旧延迟线残留。

## 必须通过的证据
1. 512 样点 FIR 标量/SIMD 指纹与独立整数模型匹配；加速非零且快于标量。
2. 动态 PUSH=512、VRED=512、VUPD=0；VFFT 实际执行且次数完整。
3. `--corrupt-fir` 必须在 0x38C8 被拒绝，返回 `ACOUSTIC_RTL_FAIL`。
4. 真实 RTL PDM 管脚位流产生非零 PCM，捕获原始数据与 FIFO 中 DAS/FIR 逐样点精确比较。
5. 真实 RV32 生产固件至少完成三轮定位、转向锁定，音频持续输出，无 trap/丢样/错误。
6. 连续流 1200 样点包含极值、历史回绕、分数/大延迟、转向忙保持、CPU 并发 PUSH；FIFO 溢出负例计数必须准确。故意替换原始bank形成不连续快照，必须输出LIVE_SEQUENCE_REJECTED，错误码2且未完成定位。
7. 样点最大处理时间必须不超过 819 拍（1024 拍预算的 80%）。
8. Vivado 全器件实现 setup/hold 均非负，且输出同一次实现的 bit/XSA。综合通过不能替代布线时序。

## ARM 与上板
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_acoustic_ps.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_acoustic_ps.ps1 -Live
```

两套 ARM 程序用 DDR 链接脚本；ITCM/DTCM 镜像分别验证 SHA256，不使用旧 OCM 程序。生产 ELF 为 `build/acoustic_arm/live_das.elf`。它消费 FIFO 到 DDR 环形缓冲 `live_audio_ring`，默认运行 23,437,500 个样点（10 分钟），结束检查定位轮次、异常、丢样和处理期限，并要求存在非零 FIR 输出、观察到转向锁定且八路 frozen 掩码为零，打印 `LIVE_DAS_PASS/FAIL`。环形缓冲只保留最近 4096 条，不是全程录音或网络音频产品。

2026-10-11 用户确认暂未连接硬件。当前不得声称物理麦克风采集、十分钟板上连续运行、实际角度准确度或声场定向增益通过。连接后用本次 bit/XSA 对应的 ps7_init 和 live ELF 上板；同一版本日志与声场测试结果才算物理证据。真实诊断应用、UDP/音频回放不在本次 PL 收尾范围。
