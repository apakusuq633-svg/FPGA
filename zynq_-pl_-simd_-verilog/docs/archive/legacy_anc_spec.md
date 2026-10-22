# 工程机械驾驶座椅主动头枕降噪系统 README

> **本文描述的 ANC（主动降噪）子系统已于 2026-10-06 从仓库整体移除。**
> 文中出现的 `rtl/anc/`、`rtl/audio/`、`sw/anc_*`、`sw/ps_anc.c`、`sw/ps_tonal.c`、
> `scripts/gen_anc_hybrid.py`、`scripts/check_tonal_math.py` 等路径**都不再存在**，
> 相对链接因此也不会解析。整份文档保留在这里只有两个用途：一是复盘时能查到当时
> 为什么这么设计，二是其中的算法推导与仿真结论本身仍然成立。
> **不要照着它去找文件。**

> **项目定位**：基于 Zynq-7010 的工程机械驾驶座椅主动头枕系统。  
> **核心目标**：针对驾驶室内持续的低频机械噪声，在左右耳附近形成稳定、可重复的双耳 Quiet Zone；系统自动从宽带机械声中识别稳定窄带/阶次成分，将其交给多通道窄带 ANC，同时把剩余低频宽带部分交给 MIMO FxNLMS。  
> **第一版声源**：信号发生器 / AWG / PC 合成机械噪声。  
> **最终版声源**：真实工程机械 WAV 录音回放。  
> **实时闭环**：ADC → PL → SIMD-MAC → DAC 保持在 PL 内。  
> **频谱分析与资源分配**：PS A9 负责，不把复杂 FFT/判决逻辑硬塞进逐采样 PL 闭环。

---

# 1. 最终推荐方案

本项目最终采用：

# **基于自适应频谱分解的 2×2 MIMO 混合主动噪声控制**

英文可写为：

> **Adaptive Spectral-Decomposition 2×2 MIMO Hybrid ANC**

核心思想不是把 50–300 Hz 全部用同一种算法处理，而是先判断：

\[
\boxed{\text{哪些是稳定、可预测的窄带成分}}
\]

再把低频声场分成两部分：

\[
x(n)=x_{\mathrm{tonal}}(n)+x_{\mathrm{residual}}(n)
\]

其中：

\[
x_{\mathrm{tonal}}(n)
\rightarrow
\text{MIMO Narrowband ANC}
\]

\[
x_{\mathrm{residual}}(n)
\rightarrow
\text{MIMO Broadband FxNLMS}
\]

最终两个支路共同产生：

\[
y_s(n)=
y_{s,\mathrm{tonal}}(n)+
y_{s,\mathrm{broadband}}(n)
\]

其中：

- \(s=L,R\)
- \(L\)：左头枕扬声器
- \(R\)：右头枕扬声器

---

# 2. 为什么要做“自适应频谱分解”

真实工程机械声音一般不是纯窄带，也不是完全平坦的宽带噪声。

更接近：

\[
x(t)=
x_{\mathrm{order}}(t)
+
x_{\mathrm{tonal,nonorder}}(t)
+
x_{\mathrm{broadband}}(t)
+
x_{\mathrm{transient}}(t)
\]

例如某一段驾驶室录音可能包含：

```text
60 Hz      强阶次
120 Hz     强阶次
178 Hz     稳定窄带峰
50–300 Hz  连续低频背景
>300 Hz    语音、高频机械声、报警等
```

如果把全部 50–300 Hz 都交给长 FIR FxNLMS：

- 计算量大
- 收敛速度慢
- 强阶次本来可以更高效地处理
- 宽带控制器会浪费资源追踪明显的窄带峰

如果只做窄带 ANC：

- 无法处理真实机械录音中的低频连续背景
- SIMD-MAC 负载不足
- 工程适应性弱

所以本项目采用：

\[
\boxed{
\text{稳定窄带} \rightarrow \text{窄带 MIMO ANC}
}
\]

\[
\boxed{
\text{剩余低频宽带} \rightarrow \text{宽带 MIMO FxNLMS}
}
\]

---

# 3. 不推荐用“超窄 FIR”直接切窄带

“把窄带切出来”不意味着：

```text
宽带信号
↓
58–62 Hz 窄带 FIR
↓
118–122 Hz 窄带 FIR
↓
178–182 Hz 窄带 FIR
```

这种方法的问题是：

\[
\boxed{\text{带宽越窄，滤波器通常越长，群时延越大}}
\]

ANC 对延迟非常敏感，因此不建议在逐采样 ANC 闭环里堆大量高阶超窄带 FIR。

推荐方法是：

1. **检测频率 \(f_k\)**
2. 不重构整段窄带波形
3. PL 内使用 phase-continuous NCO 产生正交参考
4. 自适应学习该频率所需的幅值和相位

即：

\[
f_k
\rightarrow
\sin(2\pi f_kn/f_s)
\]

\[
f_k
\rightarrow
\cos(2\pi f_kn/f_s)
\]

然后：

\[
y_k(n)
=
w_{k,s}\sin(\omega_kn)
+
w_{k,c}\cos(\omega_kn)
\]

---

# 4. 总体系统架构

```text
                        ┌─────────────────────────────┐
                        │            PS               │
                        │                             │
                        │  A9#0                       │
                        │  UI / Alarm / Logging       │
                        │  Parameter Management       │
                        │                             │
                        │  A9#1                       │
                        │  FFT / STFT                 │
                        │  Tonal Detection            │
                        │  Persistence Check          │
                        │  Coherence Analysis         │
                        │  Fault Diagnosis            │
                        │  Tone Slot Allocation       │
                        └──────────────┬──────────────┘
                                       │ AXI-Lite / DMA
                                       │
┌──────────────────────────────────────▼──────────────────────────────┐
│                                PL                                  │
│                                                                    │
│ ADC / I2S                                                          │
│   │                                                                │
│   ├──────────────→ Raw Audio DMA → PS                              │
│   │                                                                │
│   ▼                                                                │
│ Sample Buffer                                                      │
│   │                                                                │
│   ├────────→ Tonal Branch                                          │
│   │             │                                                  │
│   │             ▼                                                  │
│   │     Phase-continuous NCO                                       │
│   │     sin/cos @ f1...fK                                          │
│   │             │                                                  │
│   │             ▼                                                  │
│   │      2×2 MIMO Narrowband ANC                                   │
│   │                                                                │
│   └────────→ Residual Broadband Branch                             │
│                 │                                                  │
│                 ▼                                                  │
│          Dynamic Notch Bank                                        │
│                 │                                                  │
│                 ▼                                                  │
│          50–300 Hz FxNLMS                                          │
│                                                                    │
│                    ┌──────────────┐                                │
│                    │ PL RISC-V    │                                │
│                    │ Scheduling   │                                │
│                    │ Tone Slots   │                                │
│                    │ Kernel Ctrl  │                                │
│                    └──────┬───────┘                                │
│                           │                                        │
│                           ▼                                        │
│                    SIMD-MAC Array                                  │
│                           │                                        │
│                ┌──────────┴──────────┐                             │
│                ▼                     ▼                             │
│           Left ANC Out          Right ANC Out                      │
│                │                     │                             │
│               DAC                   DAC                            │
└────────────────┼─────────────────────┼─────────────────────────────┘
                 │                     │
                 ▼                     ▼
             Speaker L             Speaker R
                 │                     │
                 └────── Acoustic Field ──────┐
                                               │
                                  ┌────────────┴────────────┐
                                  ▼                         ▼
                              Error L                   Error R
                                  │                         │
                                  └────── ADC → PL ────────┘
```

---

# 5. PS / PL / RISC-V / SIMD-MAC 分工

这是整个项目必须讲清楚的地方。

## 5.1 PL

负责：

- ADC / I2S 多通道同步采集
- DAC / I2S 输出
- Sample-level ANC 闭环
- NCO
- Dynamic Notch
- FIR
- Filtered-X
- MIMO matrix MAC
- Adaptive weight update
- Output limiting
- deadline watchdog

特点：

\[
\boxed{\text{确定时延 + 低 jitter}}
\]

---

## 5.2 PS A9#1

负责：

- FFT / STFT
- 窄带峰检测
- 阶次跟踪
- persistence 判断
- coherence 分析
- tone slot 选择
- 故障诊断
- 真实录音分析

特点：

\[
\boxed{\text{frame-level signal intelligence}}
\]

它不进入每个 sample 的实时闭环。

---

## 5.3 PS A9#0

负责：

- UI
- 参数配置
- 工况切换
- 日志
- 报警
- 网络通信
- 性能统计
- 模式管理

---

## 5.4 PL RISC-V

RISC-V 不和 A9 比通用算力。

它负责：

- 实时 kernel 调度
- tone slot 状态机
- SIMD-MAC 配置
- coefficient bank 切换
- sample deadline 管理
- fault / freeze / restart 状态
- mode switching

原则：

\[
\boxed{\text{A9 决定“算什么”，RISC-V 决定“什么时候算”，SIMD-MAC 负责“快速算”}}
\]

---

## 5.5 SIMD-MAC

真正承担：

- MIMO FIR
- Filtered-X
- Secondary Path convolution
- Broadband FxNLMS
- MIMO Narrowband update
- Matrix-vector MAC
- Adaptive coefficient update

---

# 6. 声学结构

推荐主动头枕：

```text
                 Driver Head

              👂           👂
              E_L         E_R

           Mic L ●       ● Mic R

           🔊                 🔊
        Speaker L          Speaker R

           ┌─────────────────┐
           │    HEADREST     │
           └─────────────────┘
```

建议第一版：

- 2 个 Error Mic
- 2 个 Headrest Speaker
- 1 个 Primary Reference
- 1 个 Primary Noise Speaker

后续再升级 Virtual Sensing。

---

# 7. 第一版声源

第一版使用信号发生器、AWG 或 PC 合成。

推荐四级测试。

## Stage 1：单正弦

```text
100 Hz
150 Hz
200 Hz
```

目的：

- 验证 ADC / DAC
- 验证闭环符号
- 验证 Secondary Path
- 验证收敛
- 验证延迟

---

## Stage 2：多阶次

例如：

\[
x(t)=
A_1\sin(2\pi 60t)
+
A_2\sin(2\pi 120t)
+
A_3\sin(2\pi 180t)
+
A_4\sin(2\pi 240t)
\]

建议幅值：

```text
60 Hz  : 1.00
120 Hz : 0.70
180 Hz : 0.45
240 Hz : 0.30
```

---

## Stage 3：阶次 + 低频宽带

\[
x(t)
=
x_{\mathrm{order}}(t)
+
n_{50-300}(t)
\]

推荐第一轮：

```text
Tonal     : 70%
Broadband : 30%
```

然后逐步改成：

```text
50 / 50
30 / 70
```

测试算法的资源分配能力。

---

## Stage 4：变转速

模拟：

```text
1200 rpm
→ 1500 rpm
→ 1800 rpm
→ 2100 rpm
→ 1800 rpm
```

NCO 必须：

\[
\boxed{\text{phase continuous}}
\]

不能频率一更新就清零相位。

---

# 8. 最终版真实录音

最终使用工程机械 WAV：

- 挖掘机
- 装载机
- 叉车
- 矿山机械
- 工程车辆

推荐工况：

1. 怠速
2. 稳态低转速
3. 稳态中转速
4. 稳态高转速
5. 升速
6. 液压动作
7. 发动机 + 液压联合
8. 冷却风扇高速

格式建议：

```text
48 kHz
24 bit PCM WAV
```

最低：

```text
48 kHz
16 bit PCM WAV
```

---

# 9. Tonal Detector：如何判断哪些窄带值得切出来

不能只看 FFT 峰值。

推荐使用三类指标：

# **Prominence + Persistence + Coherence**

---

## 9.1 Prominence

定义局部峰突出度：

\[
P_{\mathrm{prom}}(f_k)
=
P(f_k)-P_{\mathrm{local}}(f_k)
\]

第一版可以把阈值设成可调：

```text
6–10 dB
```

这只是工程初始阈值，不作为理论固定值。

---

## 9.2 Persistence

一个频率必须连续存在多个 frame。

例如：

```text
FFT frame = 100 ms
Persistence = 5 frames
```

那么：

\[
T_{\mathrm{persist}}=500\text{ ms}
\]

只有持续约 0.5 s 的稳定峰才申请 Tone Slot。

这样可以避免：

- 撞击声
- 说话声
- 瞬态报警
- 短暂噪声

被误认为 ANC 窄带目标。

---

## 9.3 Coherence

计算参考与误差位置之间的：

\[
\gamma^2_{xe}(f)
=
\frac{|S_{xe}(f)|^2}
{S_{xx}(f)S_{ee}(f)}
\]

只有参考信号能够较好预测的频率，才适合进入前馈 ANC。

建议不是简单：

```text
peak exists → control
```

而是：

```text
peak exists
AND persistent
AND coherent
→ allocate tone slot
```

---

# 10. Tone Slot 状态机

这是本方案新增的核心模块。

每个窄带控制频点对应一个 Tone Slot。

状态：

```text
EMPTY
↓
CANDIDATE
↓
ACTIVE
↓
HOLD
↓
RELEASE
↓
EMPTY
```

---

## EMPTY

没有目标频率。

---

## CANDIDATE

检测到新峰：

```text
prominence > threshold
```

开始累计 persistence。

---

## ACTIVE

满足：

```text
prominence
+
persistence
+
coherence
```

后：

```text
allocate NCO
allocate coefficient set
enable MIMO narrowband controller
enable broadband notch
```

---

## HOLD

短时间峰值变弱，不立即释放。

防止：

```text
ACTIVE ↔ EMPTY
```

不断抖动。

---

## RELEASE

如果频率：

- 长时间消失
- coherence 下降
- 被判定为瞬态
- 超出控制频带

则：

```text
ramp down narrowband controller
remove notch gradually
release slot
```

必须渐变，不允许瞬间切换。

---

# 11. Tone Slot 数量

Zynq-7010 第一版建议：

```text
Kmax = 4
```

最终：

```text
Kmax = 8
```

不建议第一版做 16 个以上。

原因：

- 真实工程里最强的窄带峰数量通常有限
- 减少调试复杂度
- 保留资源给 Broadband FxNLMS

---

# 12. 多通道窄带控制

每个 Tone Slot 不是一个 SISO 正弦控制器，而是：

\[
\boxed{\text{2 Speaker × 2 Ear MIMO}}
\]

对于频率 \(f_k\)：

\[
\begin{bmatrix}
e_L\\
e_R
\end{bmatrix}
=
\begin{bmatrix}
d_L\\
d_R
\end{bmatrix}
+
\begin{bmatrix}
S_{LL}(f_k)&S_{LR}(f_k)\\
S_{RL}(f_k)&S_{RR}(f_k)
\end{bmatrix}
\begin{bmatrix}
y_L\\
y_R
\end{bmatrix}
\]

目标：

\[
J_k=
w_L|e_L(f_k)|^2+
w_R|e_R(f_k)|^2+
\lambda\|\mathbf y_k\|^2
\]

默认：

\[
w_L=w_R=1
\]

---

# 13. 为什么不是两个独立 SISO

错误：

```text
Left Mic → Left ANC → Left Speaker

Right Mic → Right ANC → Right Speaker
```

因为：

\[
S_{LR}\neq0
\]

\[
S_{RL}\neq0
\]

左右扬声器会串扰到另一只耳。

因此必须联合考虑：

\[
\boxed{\mathbf S(f_k)}
\]

---

# 14. Broadband Residual Branch

当频点：

```text
60 Hz
120 Hz
180 Hz
```

已经交给 Narrowband ANC 后，Broadband FxNLMS 不应该继续强烈追踪这些频点。

否则两个控制器会争抢同一频率。

所以 Broadband Reference 使用：

\[
x_{\mathrm{BB}}
=
H_{\mathrm{BP}}
\left[
\prod_{k=1}^{K}
H_{\mathrm{notch},k}
\right]x
\]

其中：

\[
H_{\mathrm{BP}}
\]

约束控制范围：

\[
50\sim300\text{ Hz}
\]

而：

\[
H_{\mathrm{notch},k}
\]

对应已被分配给窄带控制器的频率。

---

# 15. Dynamic Notch 要求

Notch 不允许瞬间插入。

推荐：

```text
0%
→ 20%
→ 40%
→ 60%
→ 80%
→ 100%
```

逐渐增加深度。

Tone Slot 释放时反向渐退。

目的：

- 防止瞬态
- 防止点击声
- 防止 Broadband Controller 突然失去某个频率导致权值突变

---

# 16. Broadband FxNLMS

Broadband 支路控制：

\[
50\sim300\text{ Hz}
\]

剩余低频成分。

建议第一版：

```text
Lw = 64 taps
Ls = 64 taps
```

再升级：

```text
Lw = 128 taps
Ls = 128 taps
```

不要一开始就 256 / 512 taps。

---

# 17. MIMO Broadband Cost Function

双耳目标：

\[
J(n)=
w_L e_L^2(n)+
w_R e_R^2(n)+
\lambda \|\mathbf W(n)\|^2
\]

Normalized update：

\[
\mathbf w_s(n+1)
=
\mathbf w_s(n)
-
\frac{
\mu
}{
\delta+
\sum_m
\|\mathbf x'_{sm}(n)\|^2
}
\sum_m
w_m e_m(n)\mathbf x'_{sm}(n)
\]

---

# 18. 为什么使用 FxNLMS 而不是纯 FxLMS

因为真实录音：

- 幅值会变化
- 工况会变化
- 阶次会变化
- 参考能量会变化

归一化后：

\[
\mu_{\mathrm{eff}}
=
\frac{\mu}
{\delta+\|\mathbf x'\|^2}
\]

调参更稳定。

---

# 19. Secondary Path Matrix

2×2 系统包含：

```text
S_LL
S_LR
S_RL
S_RR
```

它们包括：

```text
DAC
→ amplifier
→ speaker
→ air
→ head / seat reflection
→ error mic
→ ADC
```

---

# 20. Secondary Path Identification

第一版：

\[
\boxed{\text{Offline Identification}}
\]

ANC OFF。

分别激励：

```text
Speaker L
Speaker R
```

使用：

```text
50–500 Hz band-limited noise
```

记录：

```text
Error L
Error R
```

得到：

\[
\hat S_{LL},\hat S_{LR},\hat S_{RL},\hat S_{RR}
\]

---

# 21. 最终版 Secondary Path Tracking

最终可增加低速路径跟踪。

例如每：

```text
0.5–2 s
```

检查一次路径变化。

如果：

\[
\|\Delta \hat S\|>\gamma
\]

则：

1. 降低 adaptation step
2. freeze broadband update
3. 保留安全窄带控制
4. 更新 secondary model
5. soft restart

---

# 22. 最大化降噪：频率资源优先级

不要平均分配控制资源。

推荐使用：

\[
Score(f_k)
=
\alpha P_{\mathrm{prom}}
+
\beta P_{\mathrm{persist}}
+
\gamma C(f_k)
+
\eta E(f_k)
\]

其中：

- \(P_{\mathrm{prom}}\)：峰值突出度
- \(P_{\mathrm{persist}}\)：持续性
- \(C(f_k)\)：coherence
- \(E(f_k)\)：频点能量

Tone Slot 按 Score 排序。

如果：

```text
Kmax = 4
```

但检测到：

```text
8 个候选频率
```

只选择最值得控制的 4 个。

这比“把所有峰都切出来”更加合理。

---

# 23. 动态 SIMD 资源分配

本项目可以把 SIMD-MAC 做成可配置资源池。

## Tonal-dominant

如果：

\[
P_{\mathrm{tonal}}\gg P_{\mathrm{broadband}}
\]

则：

```text
更多 lane → narrowband MIMO
减少 broadband kernel 活跃率
```

---

## Broadband-dominant

如果：

\[
P_{\mathrm{broadband}}\uparrow
\]

则：

```text
更多 lane → FIR / Filtered-X
```

---

## Low-load

如果只检测到少量稳定 Tone：

```text
clock gate unused MAC lanes
```

形成：

\[
\boxed{\text{算力随声场复杂度动态调整}}
\]

这是非常适合你们 RISC-V/SIMD-MAC 的架构创新点。

---

# 24. 建议 SIMD-MAC 规模

Zynq-7010：

```text
第一版：4-lane
目标版：8-lane
```

建议优先：

\[
\boxed{\text{8-lane + time multiplexing}}
\]

而不是直接全展开 32-lane。

---

# 25. 采样率

推荐：

\[
f_s=48\text{ kHz}
\]

即使 ANC 只控制：

\[
50\sim300\text{ Hz}
\]

也保留 48 kHz。

原因：

- Codec 兼容
- WAV 回放方便
- 故障诊断需要高频原始信息
- 避免 ANC 与诊断使用两套完全不同的采集链路

---

# 26. 延迟目标

总延迟：

\[
T_d=
T_{ADC}
+
T_{buffer}
+
T_{compute}
+
T_{DAC}
+
T_{amp}
+
T_{speaker}
\]

最重要的是：

\[
\boxed{\text{低且固定}}
\]

建议把：

```text
digital ADC→DAC latency < 100 us
```

作为设计目标，而不是提前宣称已达到。

必须最终实测：

- mean latency
- max latency
- min latency
- jitter

---

# 27. 防发散设计

必须包括：

## Output Limit

\[
|y(n)|<Y_{\max}
\]

## Weight Limit

\[
|w_i|<W_{\max}
\]

## Error Watchdog

如果：

\[
P_e>P_{\mathrm{threshold}}
\]

持续若干 frame：

```text
freeze update
↓
ramp output down
↓
check secondary path
↓
restart
```

---

# 28. Tonal Controller Soft Start

新 Tone Slot 激活：

```text
0%
→ 25%
→ 50%
→ 75%
→ 100%
```

避免：

- 爆音
- 相位错误导致瞬间增噪
- 新控制器与 Broadband 支路冲突

---

# 29. 第一版开发路线

严格按照以下顺序。

## Phase 0

```text
ADC / DAC loopback
```

---

## Phase 1

```text
100 Hz
1 Speaker
1 Error
SISO
```

---

## Phase 2

```text
100 / 150 / 200 Hz
Tone Detector
```

---

## Phase 3

```text
Tone Slot FSM
```

实现：

```text
EMPTY
CANDIDATE
ACTIVE
HOLD
RELEASE
```

---

## Phase 4

```text
2 Speaker
2 Error
2×2 Narrowband MIMO
```

---

## Phase 5

```text
50–300 Hz Broadband FxNLMS
```

---

## Phase 6

```text
Dynamic Notch
```

---

## Phase 7

```text
Adaptive Spectral Decomposition
=
Narrowband + Broadband
```

---

## Phase 8

```text
Variable RPM / frequency sweep
```

---

## Phase 9

```text
Recorded machinery WAV
```

---

## Phase 10

```text
Fault Diagnosis
```

---

# 30. 推荐实验模式

比赛 UI 建议：

```text
[ANC OFF]

[SISO]

[MIMO Narrowband]

[MIMO Broadband]

[Adaptive Hybrid]
```

---

# 31. 必须做的对照实验

## Test A：ANC OFF

基线。

---

## Test B：SISO Narrowband

验证单点限制。

---

## Test C：2×2 MIMO Narrowband

验证双耳联合降噪。

---

## Test D：2×2 MIMO Broadband

验证低频连续声。

---

## Test E：Adaptive Hybrid

验证：

\[
\boxed{
\text{Detected Tonal}
+
\text{Residual Broadband}
}
\]

的优势。

---

# 32. 评价指标

## 左耳

\[
NR_L=
10\log_{10}
\frac{P_{L,\mathrm{off}}}
{P_{L,\mathrm{on}}}
\]

## 右耳

\[
NR_R=
10\log_{10}
\frac{P_{R,\mathrm{off}}}
{P_{R,\mathrm{on}}}
\]

## 平均

\[
NR_{\mathrm{avg}}=
\frac{NR_L+NR_R}{2}
\]

## 最差耳

\[
NR_{\min}=
\min(NR_L,NR_R)
\]

## Tonal Reduction

分别记录：

```text
f1
f2
f3
...
```

## Broadband Reduction

\[
NR_{50-300}
\]

## Tone Detection

记录：

- precision
- false activation
- activation delay
- release delay

## Hardware

记录：

- LUT
- FF
- BRAM
- DSP
- Fmax
- power
- MMAC/s
- lane utilization

---

# 33. 头部位置鲁棒性

至少测试：

```text
Center
Left 5 cm
Right 5 cm
Forward 5 cm
Backward 5 cm
```

最终：

```text
±10 cm
```

比较：

\[
NR_L(\mathbf r)
\]

和：

\[
NR_R(\mathbf r)
\]

---

# 34. Virtual Sensing 升级

第一版：

```text
Error Mic 放耳旁
```

最终：

```text
Physical Mic
→ Transfer Model
→ Virtual Ear Error
```

得到：

\[
\hat e_L,\hat e_R
\]

这是产品化的重要升级，而不是第一版必做项。

---

# 35. 故障检测链路

故障诊断使用：

\[
x_{\mathrm{raw}}
\]

不能只用：

\[
e(n)
\]

建议：

```text
Raw Acoustic
↓
Bandpass / Denoise
↓
FFT / STFT
↓
Envelope
↓
Features
↓
Classifier
```

第一版：

```text
Normal
Imbalance
Looseness
Bearing Fault
```

---

# 36. 为什么 Adaptive Hybrid 特别适合真实录音

信号发生器阶段可能是：

```text
60
120
180
240 Hz
```

最终真实录音可能变成：

```text
58.7 Hz
117.5 Hz
176.1 Hz
205 Hz stable tone
+
continuous broadband
```

如果频率固定写死：

```text
60 / 120 / 180
```

系统适应性差。

Adaptive Hybrid 可以：

```text
detect
↓
rank
↓
allocate
↓
track
↓
release
```

所以从：

\[
\boxed{\text{合成声源}}
\]

升级到：

\[
\boxed{\text{真实机械录音}}
\]

不需要重写整套控制架构。

---

# 37. 评委可能追问的问题

## 为什么不用一个宽带 FxLMS 全做？

回答：

强稳定音调可以用正交窄带控制更高效地处理；剩余低频连续噪声再由 Broadband FxNLMS 控制，可以减少无效计算并改善收敛。

---

## 为什么不用窄带 FIR 直接切出来？

回答：

超窄带 FIR 会带来更大的群时延。本系统只检测目标频率，PL 使用 phase-continuous NCO 生成正交参考，避免在实时闭环里使用大量高阶超窄带滤波器。

---

## 为什么多通道窄带？

因为两个耳位的：

\[
A_L,\phi_L
\]

和：

\[
A_R,\phi_R
\]

不同，而且左右扬声器存在交叉声学路径，所以必须联合优化。

---

## 为什么要 PS 做 Tone Detection？

因为 FFT、coherence、persistence 属于 frame-level 分析，不要求 sample-level 固定时延。A9 更适合这些复杂控制逻辑。

---

## 为什么还需要 PL RISC-V？

因为频率列表下发之后，PL 仍需要在每个采样周期内完成确定性 kernel 调度、Tone Slot 激活、系数管理和 SIMD-MAC 控制。

---

## 为什么需要 SIMD-MAC？

不是因为 4 个正弦波，而是因为：

```text
2×2 MIMO
+
Broadband FIR
+
Filtered-X
+
Secondary Path
+
Adaptive Update
+
Multi-tone MIMO
```

形成持续的规则 MAC workload。

---

# 38. 最终项目定义

> **基于 Zynq PS/PL 异构架构的工程机械主动头枕系统，通过 PS 端实时分析机械噪声频谱，依据峰值突出度、持续性和参考—误差相干性动态提取值得主动控制的稳定窄带成分，并在 PL 端采用 2×2 MIMO 多通道窄带 ANC 对其进行低时延控制；剩余 50–300 Hz 低频宽带噪声由 MIMO FxNLMS 处理。自研 RISC-V 负责 PL 内实时资源调度，SIMD-MAC 加速多通道 FIR、Filtered-X、矩阵乘加与自适应更新，同时 PS 完成故障诊断、系统管理与可视化。**

---

# 39. 最终核心创新逻辑

整个项目不再只是：

```text
FPGA + FxLMS
```

而是：

\[
\boxed{
\text{真实宽带声场}
\rightarrow
\text{频谱分析}
\rightarrow
\text{动态任务分解}
\rightarrow
\begin{cases}
\text{MIMO Narrowband ANC}\\
\text{MIMO Broadband ANC}
\end{cases}
}
\]

再映射到：

\[
\boxed{
\text{PS：分析与决策}
}
\]

\[
\boxed{
\text{PL RISC-V：实时调度}
}
\]

\[
\boxed{
\text{SIMD-MAC：确定性并行计算}
}
\]

这才是本项目最完整、最适合比赛答辩的技术主线。

---

# 40. 第一版实现与验收（2026-09-21）

本节记录第一版**实际做出来的东西**、实测数字、以及与上文规格**有意不一致**的地方。
上文是规格，本节是实现；两者冲突时以本节为准，并说明为什么偏离。

## 40.1 落在哪几个文件

| 层 | 文件 | 干什么 |
|---|---|---|
| PL 硬件 | [rtl/anc/rv32_anc_regs.v](rtl/anc/rv32_anc_regs.v) | 4 槽相位连续 NCO、6 级双二阶链（2 级带通 + 4 级动态陷波）、窄带 MIMO 输出累加、参考样点 FIFO |
| PL 阵列 | [rtl/vec/rv32_vec_unit.v](rtl/vec/rv32_vec_unit.v) | x′ 延迟线由 2 条扩到 **4 条**（2×2 MIMO 的 filtered-x 需要 x′_LL/LR/RL/RR 各一条） |
| 固件 | [scripts/gen_anc_hybrid.py](scripts/gen_anc_hybrid.py) → `sw/anc_hybrid.hex/.h` | 逐样点宽带 2×2 FxNLMS + 窄带权重更新 + 限幅 |
| PS 帧级 | [sw/ps_tonal.c](sw/ps_tonal.c)、[sw/ps_tonal.h](sw/ps_tonal.h) | FFT + prominence/persistence/coherence + Score 排序 + Tone Slot 五态机（§9/§10/§11/§22） |
| 验证 | [scripts/check_tonal_math.py](scripts/check_tonal_math.py)、`gen_anc_hybrid.py --check` | 宿主侧纯算术检查 + 闭环 NR |

## 40.2 实测数字（`gen_anc_hybrid.py --check`）

激励按 §7 Stage 3：60/120/180/240 Hz 四个阶次 + 50–300 Hz 带限宽带；
被控对象是 2×2 次级通路（对角 0.55/0.52、交叉 0.16/0.14，各带两个反射）+ 两路初级通路。
1536 个样点（= 39 ms @39.0625 kHz），NR 从第 256 帧起算：

| 对照 | 配置 | NR |
|---|---|---|
| Test A | ANC OFF | **0.00 dB** |
| Test C | 只开窄带 | **7.56 dB** |
| Test D | 只开宽带 | **20.86 dB** |
| Test E | **混合**（§31） | **16.93 dB** |

Test A 的 0.00 dB 是反空转检查 —— 全关时误差必须原样返回，否则激励自己凑巧抵消
也能让 NR 好看。

> ⚠ **Test E 目前低于 Test D**，§31 要证的「混合优于两条单独支路」**还没做到**，
> `--check` 因此**故意红着**。原因**不是** §40.7 猜的那条（"陷波只压到 −20 dB / 双二阶状态 16 位"）
> —— 那条已被 §40.9 推翻：真相是**音调支路一直是关的**。026 把陷波换成投影之后再量，
> 投影开 D=15.95 / E=16.75，关掉则是 D=20.86 / E=16.93 ——
> **E 打不过 D 是关掉音调支路时的现象**：宽带支路那 20.86 dB 大半在消音调，不是它的本职。
> 把音调交回窄带支路之后 D 反而掉下来，说明抢占频点这件事**两种结构下都存在**。
> 这一格仍红，且**不是换结构能解决的** —— §31 的问题在控制律，见 §40.6 / §40.9。

## 40.3 与规格有意不一致的地方（都要在答辩时说清楚）

1. **采样率是 39.0625 kHz，不是 48 kHz。** §25 要求 48 kHz，但 40 MHz 的 PL 时钟分不出
   12.288/3.072 MHz 的整数比，要么加 MMCM 破掉「单时钟域」这条结构约束（verify.ps1 第 3 项），
   要么接受 clk/1024。选了后者，理由见 [rtl/audio/rv32_audio_clkgen.v](rtl/audio/rv32_audio_clkgen.v) 头部。
   NCO 频率字、PS 的频率→增量换算全部按 39062.5 Hz 定标。
2. **窄带 MIMO 的累加在 PL 硬件里，不在 SIMD-MAC 上。** §5.5 把「MIMO Narrowband update」
   列在 SIMD-MAC 名下。实际做成了：**累加**在 ANC 外设（16 个乘加/样点），**权重更新**在固件
   （每样点一个 (s,k) 对，8 拍轮询）。原因：预算 1024 拍/样点，宽带 2×2 FxNLMS 已经吃掉约 169 拍
   SIMD + 约 150 拍标量，48 个窄带乘加全塞固件放不下。这同时让 §10 的 ACTIVE
   （"allocate NCO / allocate coefficient set / enable MIMO narrowband controller"）变成**真的**
   在分配硬件资源。§23 的「时分级复用」体现在 8 拍轮询上。
3. **第一版的参考不走参考麦。** 板上 WM8960 只有 **2 个 ADC**，§6 要的「2 误差麦 + 1 参考」
   是 3 路，硬件上放不下。第一版把参考做成一条**独立数字通路**（ANC 外设的参考 FIFO，
   PS 经 AXI 写、或 TB 直驱），误差麦用满两路。这正好落在 §7「第一版声源用信号发生器 /
   AWG / PC 合成」的范围内，也绕开了参考麦的声反馈与因果性摆位约束（§37 那三个经典难点）。
   上板要做 2×2 需要在 PL 上再挂一片 I2S ADC（旧 README 记过这一步）。
4. **陷波系数是 Q14 不是 Q15。** a1 = −2ρcosω 峰值接近 2.0，Q15 装不下会溢出；
   Q14（1.0 = 16384）刚好，`>>14` 出 Q15。精度代价可忽略：ρ=0.9975 时陷波带宽约 31 Hz，
   而 Q14 的频率分辨率在 60 Hz 处约 0.1 Hz。
5. **NCO/陷波的软起动与深度渐变在硬件里做**，不靠固件定时（§15/§28 的意图）；
   `ramp_step_q`/`nramp_step_q` 为 0 表示立即到位。§28 的**向上**软启动由 PL 踩，
   **向下**的 RELEASE 斜坡由 `ps_tonal.c` 自己走 5 步。

## 40.4 已知的坑（这几条都是踩出来的，不是推出来的）

- **窄带次级通路的虚部符号**：参考经 ŝ 之后是 `A·sin − B·cos`（A=Σh·cos、B=Σh·sin）。
  写成 `+` 不是「收敛慢」，是**发散**。脚本开头有一段冲激实测把这条钉死。
- **限幅会伪装成「没收敛」**：初级幅度定得太大时，抵消所需输出超过 `Y_LIMIT`，
  窄带一直顶在限幅上，NR 卡在 4.5 dB 上不去。看起来像算法问题，其实是被自己削平了。
- **小 μ 下整数截断会让更新死掉**：Δw 被两次 `>>15` 截成 0 之后，向零取整还不对称，
  表现为**发散**而不是「不收敛」。所以信号电平要顶到满量程附近，μ 不能凭感觉调小。
- **BRAM 读是两拍延迟**：ANC 序列里 ROM 地址在 t 拍发、数据 t+2 才稳；按一拍收会静默读到
  上一个地址的值 —— 表里每个值都合法，错得不显眼。
- **PS 侧 prominence 差 8 个八度**（`ps_tonal.c` 实现时抓到）：Q8 定标让比值大了 2^8 倍，
  4 倍功率被判成 30 dB 而不是 6.02 dB，§9.1 的 6 dB 门限实际变成 −18 dB。
  改成对数域相减（无除法、不溢出）。

## 40.5 还没做完的

- **`tb_anc_hybrid.v` 尚未写**：固件的黄金模型（`gen_anc_hybrid.py` 里的 `FwModel`）
  已经与硬件模型逐条对齐并跑出闭环 NR，但**还没有把 `sw/anc_hybrid.hex` 装进真 RTL 逐样点比过**。
  在补上之前，"固件在真 RTL 上算得对"这件事只有 `tb_fxlms.v` 那条 SISO 前例背书，不是本固件。
- **上板未做**：SISO 参考通路（PC 合成 → UART → PS → AXI → 参考 FIFO）可以在现有板子上跑，
  2×2 需要先加第二片 I2S ADC。
- **`ps_tonal.c` 未接进 `ps_main.c`**，也还没写进 `install_ps_app.ps1` 的文件清单。
- **H_BP 的两级带通已经不在 RTL 里了**（026 连同陷波链一起撤掉，007 实测要赔 19 dB）。
  `gen_anc_hybrid.py` 仍吐 `ANC_BP0..9` 到 `sw/anc_params.vh/.h`，留给以后真要做的线性相位 FIR；
  寄存器窗口 0x0C/0x0D 现在什么都不译码，`tb_anc_hybrid.v` 里原来那 10 次写已删。

## 40.6 陷波链已收口：换成投影相减（见 docs/issues/026）

`tb/tb_anc_notch.v` 原来照着"陷波该有的行为"写、**故意红着 4 项**，现在**通过**了 ——
但它测的已经不是陷波：6 级双二阶链（2 带通 + 4 陷波）整个从参考通路撤掉，
换成 4 槽最小二乘投影相减。判据是旁路逐样点恒等、相关器/相减的**逐位恒等式**（各 2500 帧）、
单音与四音抑制深度、带内透通、插入渐变对照。

**它仍然没接进 verify.ps1**（verify 只跑 `tb_anc_nco`），但两个 TB 都在
`scripts/run_iverilog.ps1` 的清单里。
⚠ `scripts/verify.ps1` 第 16 项那段注释（说 tb_anc_notch 现在红着 3 项、50 Hz 高通有极限环、
四级级联达不标）**已经过期**；本次按规矩没有改那个文件（里面检查项是编号的、正文有引用），
留在这里备查。

**为什么换结构**：直传型用 `a1 = -2*rho*cos(w0)` 表示陷波频率，低频处 `acos` **病态** ——
60 Hz 上系数 1 个 LSB 约等于零点跑 39 Hz，`b0=16384 b1=-32766 b2=16382` 时
`disc = b1*b1 - 4*b0*b2 = +4`，两个实零点，**根本没有陷波**。状态位宽 16 到 28 位实测一位都不动，
所以是**结构**问题不是精度问题。三次误判（陷波重叠 / 状态位宽 / 系数精度）全在 004。

| 项 | 旧（陷波链，实测） | 新（投影，实测） |
|---|---|---|
| 60 Hz 单音抑制 | -12.27 dB（ROM 取 cos）/ -2.22（host 写 cos） | **-37.06 dB**（峰值残余 -35.4 dB） |
| 四音同时最差（240 Hz） | 结构上不可能 | **-23.96 dB** |
| 带内透通（阶次之间） | — | -0.057 dB |
| 序列长度 | 68 拍 | **50 拍** |

**带通两节一并删了**：007 实测参考通路上挂 IIR 带通要赔 19 dB，默认就该是没有。
`ANC_BP0..9` 仍由生成器吐进 `anc_params.vh/.h`（留给以后真要做的线性相位 FIR），
但 RTL 里已经**没有**这两个寄存器窗口（0x0C/0x0D 现在什么都不译码）。

⚠ **投影修好的是结构，不是闭环收益**：打开投影后混合 NR 16.75 dB，
比旧陷波链的 5.87 好 **+10.88 dB**，但仍**略低于完全不陷波的 16.93**，
而且只开宽带时从 20.86 掉到 15.95 —— 参考通路去掉音调等于抽掉宽带支路正在用的信息。
**要不要打开是控制律问题**（§40.9），产物与 `tb_anc_hybrid` 都保持 `en=0`。
⚠ 而 `sw/ps_anc.c` 里 `ANC_NOTCH_EN` **默认是 1**，即板上跑的是投影打开 —— 和主机侧黄金对照不一致。

**对闭环 NR 的影响**：§40.2 那组数字是**陷波关**的配置（见 §40.9）。
## 40.7 上板前这一轮查出的两条结构性问题

### （1）仿真几何必须因果：参考必须**领先**误差

要抵消，需 `g·y(n−dS) = −gp·x(n−dP)`，即 `y(n) = −(gp/g)·x(n + dS − dP)`。
要让 y(n) 只用到 x(≤n)，就得 **dP ≥ dS**。原先写成 dP=3 / dS=8，等于要求
「预测未来 5 拍」—— 窄带靠 NCO 还能装过去（音调可预测），**宽带支路结构上不可能收敛**，
NR 一直卡在 1~7 dB，看起来像算法没调好。改成 dP=16/17、dS=8/9/10 后宽带支路才活。

物理含义就是：**参考麦必须比误差麦更靠近噪声源**。上板摆位同理，这条要在装麦之前算清楚。

### （2）参考通路上**不能**放 IIR 带通（§14 的 H_BP）

ANC 的 FIR 要实现 `w = −P/(S·H_BP)`。§14 想要的两级 IIR（50 Hz 高通 + 300 Hz 低通）
在直流有二阶零点，它的逆就是直流上的二阶极点 —— 64 抽头结构上实现不了，FxNLMS 收敛不了。
实测（1536 帧，只开宽带）：

| 参考通路 | 只开宽带 NR |
|---|---|
| 放 IIR 带通（50/300） | 1.80 dB |
| 直通 | **20.86 dB** |

差 19 dB。另外 IIR 的**频率相关群延迟**还吃因果余量（高 Q 陷波尤甚），
而线性相位 FIR 的群延迟是常数、能被次级通路模型吸收。

第一版按直通做：§14 的「约束到 50–300 Hz」由**声源本身的带限 + 被控对象**保证
（§7 Stage 3 就是这么造的）。`BP_COEFS` 仍然算好写进 `sw/anc_params.vh`，
留给第二版换成线性相位 FIR。

### 顺带修正的两处模型口径

- **宽带源不能堆在阶次上**。陷波要从参考里挖掉四个音调（ρ=0.9975 → 每个约 31 Hz 宽），
  宽带源若落在阶次上，等于一半宽带能量在参考里被挖掉、在初级里还在 —— 那段频率
  FxNLMS 无解。真实机械的连续背景本来也不堆在阶次频率上，现在每个阶次两侧各留 22 Hz。
- **陷波改零点半径式**（见 §40.6）：60 Hz 处 −8.95 → **−20.18 dB**，零点跑到 fs/4−f 的问题消失。

## 40.8 上板前还需要人工确认的

硬件侧（我做不了的部分）：

1. **参考通路怎么进板**。第一版走 ANC 外设的参考 FIFO（PS 经 AXI 写 REFDATA）。
   板上做法：PC 合成的参考信号经 UART 送 PS，PS 在帧中断里经 AXI 灌进 FIFO。
   **需要确认 UART 的带宽够**（39.0625 kHz × 2 字节 = 78 KB/s，115200 8N1 只有 11.5 KB/s
   —— 差 7 倍，所以要么用**板上自己合成参考**，要么换更快的链路）。
2. **参考与初级的同步**。窄带靠 NCO 锁相，不同步只是慢收敛；宽带支路对同步敏感。
3. **2×2 需要第二片 I2S ADC**（板上 WM8960 只有 2 个 ADC）。
4. **摆位**：参考麦必须在误差麦上游，且声程差 × 声速 > 次级通路总延迟（见 §40.7(1)）。

工具侧：

5. **Vivado 综合 + 时序** —— **已跑（2026-09-21 晚）**：

   | 配置 | WNS | 失效端点 | 关键路径 |
   |---|---|---|---|
   | Zynq **40 MHz**（产品，`run_pl_flow.tcl`） | **+0.094 ns** ✅ | **0** | 已收敛（布线后补 phys_opt，已复现） |
   | 裸 PL **50 MHz**（台面，`run_pl_bare.tcl`） | −1.436 ns | 32 | `u_ex_mem_reg` payload 自身 |

   产品那条**已收敛**（+0.094 ns，0 个失效端点，已复现并出了 bitstream）；裸 PL 50 MHz 那条仍是
   −1.436 ns，**归因未定**（见下）。40 MHz 那条原本是 **−5.799 ns / 186 端点**，关键路径在 ANC 的
   系数运算上（ρ→r→b→MAC 串了 3 级组合乘法），加 8 拍预算相位后压到 −0.413 ——
   **ANC 已不在关键路径上**（报告里从 76 次降到 13 次），详见 `docs/issues/023`。

   **剩下的 0.413 ns 归因未定**：两条失效路径的目的地都在核的 EX-MEM payload 的 D 上，
   形状像是"payload 的 D 锥本身是瓶颈"，但**没做过对照**（回退 RTL 重跑基线），
   所以只是推断。见 `docs/issues/020`。
6. **Vivado 的环境坑**：必须用 **PowerShell**（Git Bash 的 `HOME` 会让 BD 规则文件加载失败）、
   且跑之前 `Get-Process vivado` 确认没有并发实例。踩过一次，见 `docs/issues/018`。
6. `scripts/verify.ps1` 的第 16–18 项（ANC 外设 / 混合闭环 / PS 音调检测）尚未接；
   `tb_anc_hybrid.v` 尚未写；`sw/ps_tonal.c` 还没接进 `ps_main.c` 与 `install_ps_app.ps1`。

## 40.9 订正：§40.7 对「Test E 打不过 Test D」的解释是错的

§40.7 把原因归到「陷波对参考里音调的抑制只有 −20 dB，差在双二阶内部状态的 16 位量化上」。
**不对。** 真因是 `gen_anc_hybrid.py` 的 `configure()` **从来没设过音调支路的使能**，
而它的默认值是"全关" —— 数据通路里 `live = self.en[k]` 会把深度强制成 0。
**第一版的陷波一直是关的，§14「宽带支路用陷波后的参考」根本没被跑到过。**

`tb_anc_hybrid.v` 是按这份黄金文件生成的，所以它忠实地也把 `NK_CFG` 的 en 位写成 0。

三种配置的实测（1536 帧，只改 `en`）：

| | 音调支路关（当前状态 / 产物 / golden） | 旧陷波链开（§14 的正确形态） | **投影开（026 之后）** |
|---|---|---|---|
| Test A ANC OFF | 0.00 dB | 0.00 dB | 0.00 dB |
| Test C 只开窄带 | 7.56 dB | 7.56 dB | 7.56 dB |
| Test D 只开宽带 | **20.86 dB** | **3.07 dB** | 15.95 dB |
| Test E 混合 | 16.93 dB | 5.87 dB | **16.75 dB** |

关掉音调支路时宽带支路那 20.86 dB **大半是在消音调**，不是它的本职工作。开旧陷波链后它只剩
3.07 dB —— 而这一段约占总功率 17.5%，3.07 dB 意味着它几乎把自己那一段消干净了，
**这才是它该有的表现**。投影把同一格抬回 15.95 dB，是结构换对之后的样子。

**但三种配置下 Test E 都打不过 Test D**，§31 的主张目前还没证到。投影让混合从 5.87 回到
16.75（+10.88 dB），但仍略低于"音调支路关"的 16.93 —— **换结构不等于有收益**，
这仍是一次控制律层面的取舍（见 §40.6）。

要开音调支路，**必须同时改三处**，只改一处会让 TB 变红：
1. `gen_anc_hybrid.py` 的 `configure()` 里把 `anc.prj.live` 置真、`anc.prj.en = [True] * K_SLOTS`
2. `tb/tb_anc_hybrid.v` 里 `NK_CFG` 的 en 位写成 1
3. 重生成 `sw/anc_expect.hex`（黄金文件跟着变）

这是一次**控制律层面的改动**，不是修 bug —— 排在开陷波后面要回答的是"混合为什么还是输给窄带"，
那才是 §31 真正要解决的问题。

## 40.10 激励配比扫描（实测，2026-09-21）

`--check` 只跑一个配比不够——**哪条支路赢取决于激励**。三档实测（1536 帧，A 恒为 0.00）：

| 激励（阶次/宽带） | 陷波 | 只窄带 | 只宽带 | 混合 |
|---|---|---|---|---|
| 70/30（§7 Stage 3 默认） | 开 | 7.56 | 3.07 | 5.87 |
| 50/50 | 开 | 2.83 | 3.20 | **4.43** |
| 30/70 | 开 | 1.71 | 1.01 | 1.27 |
| **100/0（纯阶次）** | 开 | **12.68** | 4.22 | 7.81 |
| **100/0（纯阶次）** | 关 | 12.68 | **20.16** | 16.68 |

**读法**：
- **配比越偏阶次，窄带越好**（7.56 → 12.68）。理论上限从 9.64 dB 变成无穷，
  实测窄带消掉约 **94.6%** 的阶次功率。柴油机正是阶次主导 —— 趋势对我们有利。
- **纯阶次下只宽带的 20.16 dB 是彻底的假数**：它在 100/0 的物理上限是 **0 dB**
  （没有它该管的东西），20.16 全部来自替窄带干活。同理 70/30 的 20.86。
- **混合只在 50/50 上赢过两条单支路**（4.43 > 2.83 / 3.20），其余配比都输给窄带单独。
  §31 的主张**只在均衡配比下成立**，且幅度小（+1.2 dB）。

**由此得一条直接可用的结论**：**纯阶次工况下应该把宽带支路关掉**——
它在 100/0 下没有正当职责，开着只会抢。这正是上板程序 `sw/ps_anc.c` 里
`fromhost=0` 那个模式，也正是 §7 Stage 1/2 该跑的法。**上板第一轮不必等 004、
不必等宽带那条线，现有配置就能拿到 12.68 dB 这一档。**

**数据来源**：定点闭环模型实测（非解析）。**陷波开的那几行没有 RTL 逐位验证** ——
黄金文件与 `tb_anc_hybrid` 都是按陷波关生成的，要对上得改三处（生成器 `notch.en`、
TB 的 `NK_CFG`、重生成 expect）。**只能算模型预测。**

### 40.10.1 精细扫描：混合赢的区间是哪一段（实测，1% 一档）

`scripts/sweep_mix_nr.py --lo 0.25 --hi 0.55 --step 0.01`，结果 `build/mix_sweep_fine.md`。

| 宽带占比 | 只窄带 | 只宽带 | 混合 | 混合赢多少 |
|---|---|---|---|---|
| 25% | **5.12** | 3.54 | 5.02 | −0.10（还输） |
| **26%** | 5.00 | 3.51 | **5.02** | **+0.02 ← 翻正点** |
| 30% | 4.53 | 3.50 | 4.77 | +0.24 |
| 34% | 4.12 | 3.38 | 4.62 | +0.50 |
| 39% | 3.67 | 3.52 | 4.52 | +0.85 |
| **44%** | 3.26 | 3.50 | **4.54** | **+1.04 ← 赢面最大** |
| 50% | 2.83 | 3.61 | 4.41 | +0.80 |
| 55% | 2.51 | 3.88 | 4.56 | +0.68 |

**三个口径必须分开报，不能混着说**：
- **混合翻正的临界点**：宽带占比 **26%**（25% 还输 0.10 dB）
- **混合的绝对最大值**（区间内）：**5.02 dB @ 26%**
- **赢面最大的配比**：**44%**，领先最好单支路 **+1.04 dB**
- **整个扫描的绝对最大值**：**12.68 dB @ 0% 宽带 + 只开窄带** —— **不在混合赢的区间里**

也就是说「混合赢」和「NR 最大」**不是同一处**。按 §31 报 Test E 用 44% 那档；
报最大降噪用 0% 那档，但那时混合是输的（7.81 vs 窄带 12.68）。
