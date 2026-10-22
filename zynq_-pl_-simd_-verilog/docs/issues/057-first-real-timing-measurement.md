# 057 第一次真实时序实测：9762 个失效端点

> **✅ 2026-10-04 结案：时序已闭合。** 本文的演进终点 **−0.777 不是最终值**。
> 最终 **`WNS = +0.726 ns`、失败端点 0**（`All user specified timing constraints are met.`）。
> 收掉它的是两步**微架构改动**，不是工具参数：
> [061](061-mmio-combinational-loop-critical-path.md)（MMIO 隔拍应答）+
> [062](062-fft-butterfly-read-compute-pipeline.md)（蝶形读/算流水，只多 9 拍）。
> ⚠ 本文下面那条结论「**工具侧杠杆已全部试尽**」是对的（4 个 strategy、
> phys_opt/route 指令档、LUT 压到 45.2% 全都无效），但由此推出的
> 「**只剩改乘法器微架构这一条路**」**点错了地方** ——
> 瓶颈不是乘法器本身，而是**乘法器和异步读被压在同一拍**。

**症状** 换存储（[053](053-fft-storage-not-inferred.md)）之后，Zynq 全流程第一次
**跑完布局布线并出位流**：

```
Post Routing Timing Summary | WNS=-6.544 | TNS=-33418.992 |
Setup :  9762 Failing Endpoints,  Worst Slack -6.544ns,  Total Violation -33418.994ns
Hold  :     0 Failing Endpoints
```

**57,025 个端点里 9,762 个失效（17%）**，时钟 40 MHz / 25 ns。

**这是全设计第一次拿到真实时序数字。** `docs/issues/039` 让 `synth_design` 在这台
机器上连 4 行 blink 都崩（2026-09-22 → 10-01），**那十天里所有"综合时会怎样"的
断言一条都没被验证过**；解封之后第一次 `place_design` 又因 LUT 279% 直接失败
（053）。所以这个数字**不是回归**，是欠了两周的账一次还清。

**误判（两次，都记下来）**

1. **"先按 025 的配方补一遍布线后 phys_opt 就能回来"**。
   025 当时是 Zynq 40 MHz 上 WNS **−0.413**，靠 `phys_opt_design` + `route_design`
   转正。形状也像：那条路 **57% 是布线**，这次 **65% 是布线**。
   **工具自己拒绝了**：
   ```
   WARNING: [Physopt 32-745] Physical Optimization has determined that the magnitude
   of the negative slack is too large and it is highly unlikely that slack will be
   improved. Post-Route Physical Optimization is most effective when WNS is above -0.5ns
   ```
   实测只挪了 0.08 ns（−6.544 → −6.463）。
   **教训：025 的配方有适用区间（WNS 好于 −0.5 ns），别把它当万能药。**
   有这条 WARNING 就等于"这条路走不通"，比我自己猜快得多。

2. **"最差十条里九条在 `u_acoustic_ext`，所以问题就在那儿"**。
   十条样本太小。**必须按模块统计失效端点**（`build/timing_by_module.tcl`，
   `get_timing_paths -slack_lesser_than 0 -max_paths 2000` 再按端点归类）：

   ```
   u_core/u_acoustic_ext   1715 条   WNS -6.544     ← 86%
   u_core/u_fft_bfly        260 条   WNS -6.428     ← 13%
   u_core/u_ex_mem_reg       25 条   WNS -5.870
   ```

**根因（两个，互相独立）**

**① `u_acoustic_ext` 的 VPHAT 把一整条链塞在一拍里（86%）**

```
mz[a] 组合读(208:1) → mag_approx → recip_q14 → 复乘 → 写回 mz
                                     ↑
                        16 位优先编码器 + 两次变址移位
```
30.9 ns / 30 级逻辑 / 65% 布线。与 [023](../archive/issues/023-anc-coefficient-pipeline-timing.md)
（ANC 的 3 级乘法全组合）是同型问题，只是换了模块。

**② `u_fft_bfly` 的读地址被核的信号牵着走（13%）**

路径逐级明细（`build/timing_zynq.rpt`）说明了一切：

```
q_o_reg[101] →（核内译码）→ id_ex state → ptr_q → u_fft_bfly/io_fire
   → FFT 的**读地址 mux** → g_bank[*]...ADDRA3（扇出 256）
   → RAMD64E 读 → q_a[1] → str22__0_i_131 → CARRY4 …（整个蝶形）
```

`io_fire` 是**从核组合过来**的（`start_i & is_io_i & commit_i`），却当了
RAM 地址 mux 的选择端 —— 于是核的译码 → 地址 → 读数据 → 蝶形 → 另一片 RAM 的地址，
一条 32 级的长链。**这是我改存储时引入的**：原版 PUSH 是
`bnk[brev_w[2:0]][brev_w[8:3]] <= scalar_i`，地址来自寄存器、没有这级 mux。

**修法**

1. **VPHAT 拆三级流水**（`vph_q`）：读+幅值 / 倒数 / 复乘+写回。算术一个字没改，
   只是排到三拍上。代价 VPHAT 26 → 78 拍（整条链 1278 → 1304，可忽略）。
2. **FFT 的地址 mux 选择端改用寄存器**（`state_q == ST_IDLE`，原来的 `push_fire`
   是从核组合来的）。ST_IDLE 里写只发生在 PUSH、读只发生在 POP，两者互斥 ⇒ 判据等价。

**实测（三轮，每轮都按模块重新归因）**

| 轮次 | 改了什么 | 失效端点 | TNS | WNS |
|---|---|---:|---:|---:|
| 起点 | — | **9762** | −33418.992 | −6.544 |
| 第 2 轮 | VPHAT 拆三级流水 + FFT 地址 mux 改用寄存器 | **630** | −1799.857 | −4.415 |
| 第 3 轮 | `rv32_fft_addr` 的 9 个乘法器换成移位（[058](058-fft-addr-hidden-multipliers.md)） | **294** | **−181.491** | **−1.506** |

**失效端点降 33 倍，TNS 降 184 倍。**

**每一轮归因都整条换了地方** —— 这正是"按模块统计失效端点"这个方法在起作用的
证据，也说明**不能改完一处就以为完事了**：

- 起点：86% 在 `u_acoustic_ext`，13% 在 `u_fft_bfly`
- 修完 ①②：630 个**全部**落在 `u_fft_bfly` 的 `stage_q`/`cyc_q` → 地址发生器
- 修完 ③：294 个，最差三条换成**核自己的 `u_ex_mem_reg` payload 逻辑**（35〜38 级）
  —— 那是 [024](024-timing-was-zero-margin.md) 记的"本来就零余量"的老路径，
  和这一轮改动无关

**第 4 步：布线后补 phys_opt（不动 RTL）**

同样那一条命令，在第 2 轮时（WNS −6.5）被工具自己拒绝、只挪 0.08 ns；
在**这一轮（−1.5）却挪了 0.9 ns**：

| | 补之前 | 补之后 |
|---|---:|---:|
| WNS | −1.506 | **−0.616** |
| TNS | −181.491 | **−34.884** |
| 失效端点 | 294 | **163** |

**同一个手段在余量不同时效果完全不同** —— 这就是为什么"改之前先量"。

再迭代两遍就**收敛了**（第 2 轮 −0.616、第 3 轮 −0.604，端点数一动不动）：
`phys_opt_design` 在 −0.6 这一档已经榨干。

**剩下的 163 个端点**：TNS −34.57 / 163 ≈ 平均每条只差 **0.21 ns**，最差那条是
核自己的 `u_ex_mem_reg/u_payload_dff`（30 级，57% 是布线）——
**四个轮次之后，约束回到了 024 记的那条老路径上**，和这一轮的所有改动都无关。

**第 5 步：换实现策略 —— 负结果，但顺带把一笔旧账翻出来了**

先说清楚：Zynq 工程**本来就不是"默认策略"**。
`scripts/create_zynq_project.tcl:480` 写着

```tcl
set_property strategy Performance_NetDelay_high [get_runs impl_1]
```

而那个选择是**扫过 5 个策略比出来的**（注释里逐条列了）：
`NetDelay_high +0.105 | ExplorePostRoutePhysOpt +0.014 | Explore −0.018 |
RefinePlacement −0.135 | ExtraTimingOpt −0.500`。

**但那 5 个数是在 50 MHz（裸 PL 口径）下量的**，然后按名字搬到了 Zynq 工程上 ——
这正是 025 警告过的"时序结论跨配置套用"。**注释里自己也写了这笔账**：

> ⚠ 换到 7020 之后这一段的前提变了 …… 等 issue 039 解决、能跑通实现之后，
> **重跑五个 strategy 重新比一次**再决定去留。

这次补量了一个：

| 配置（40 MHz，Zynq 产品口径） | WNS | TNS | 端点 |
|---|---:|---:|---:|
| **`NetDelay_high` + 布线后 phys_opt**（当前最好） | **−0.604** | −34.6 | **163** |
| `Performance_RefinePlacement` | **−2.822** ✗ | −726.988 | 459 |

**方向与 50 MHz 那次一致（RefinePlacement 更差）**，但幅度大得多。
⇒ 当前最好的一版是 `NetDelay_high` + 布线后补 phys_opt，
它已经写进 `scripts/run_zynq_flow.tcl`（第 4 步）——
**必须写进去**，否则位流是从没优化过的那份实现出的。
**剩下 4 个策略的复测仍是欠账**（见 057 的"还欠的"）。

**为什么还剩 0.6 ns，以及它为什么难**

那条路径的形状是**组合式存储器应答的往返**：

```
payload → dmem_req → SoC 地址译码 → dmem_ready → dmem_write → payload 下一状态
```

`rv32_memory_stage.v` 里 `dmem_write_o` 直接依赖 `dmem_ready_i`，
而 `dmem_ready` 又是对 `dmem_req` 的组合应答 ⇒ 一条 30 级的闭环。
**这是核的架构决定**（单周期组合应答），024 记的就是它。
要真正收掉得改存储器时序协议（变成多拍应答）—— 那是**核的架构改动**，
不是"再调一个参数"。所以到这里停下来报告，而不是硬猜一个改法。

---

## 2026-10-03：**工具侧的杠杆全部用尽**（逐条实测）

到这一步 WNS 停在 **−0.777 ns / 189 个端点**，把能想到的非 RTL 手段逐条试完：

| 手段 | 结果 |
|---|---|
| 布线后补 phys_opt（默认档，025 的配方） | −1.506 → **−0.616**，再迭代两遍收敛不动 ✗ |
| `Performance_Explore` | −1.803 ✗ |
| `Performance_ExtraTimingOpt` | −1.374 ✗ |
| `Congestion_SpreadLogic_high` | −1.369 ✗ |
| `Performance_RefinePlacement` | −2.822 ✗ |
| `phys_opt_design -directive AggressiveExplore` | −1.384 ✗ |
| `route_design -directive NoTimingRelaxation` | −1.227 ✗ |
| **把 LUT 从 74.8% 压到 45.2%** | **−0.604 → −0.777，毫无帮助** ✗（[060](060-acoustic-ext-storage-not-inferred.md)）|
| 换核自己的 OOC 综合指令 | **做不到**，见下 |

**当前最好的一版 = `NetDelay_high` + 默认 phys_opt + route = −0.777**，
`scripts/run_zynq_flow.tcl` 已经固化了这条路径，且两次独立跑出**同一个数**（可复现）。

### 为什么"换核的 OOC 综合指令"这条路走不通

工程注释里写着「要压核自己的路径得单独 reset 那个 OOC 子 run —— 那是另一件事，还没做」。
这次做了，**连撞三个坑，全是"不报错"的**：

1. `set_property strategy` **对 BD 模块引用的 OOC run 不生效** —— 那种 run 有自己的
   命令模板，`runme.log` 里那行 `synth_design` 照旧没有 `-directive`。
2. 能生效的是**步骤参数** `STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE`，
   但那个 run **在 `launch_runs synth_1` 之前不存在**（是启动综合时才创建的）
   —— `get_runs` 返回空，脚本**静默走 else 分支**。**白跑两轮约 80 分钟。**
3. 就算设上了，`reset_run` 那个 OOC run 之后**模块引用解析不回来**：
   ```
   ERROR: [Runs 36-346] File '.../ps_pl_u_rv32_ps_0.xci' contains invalid reference(s)
   ERROR: [filemgmt 56-189] Failed to resolve reference ... 'rv32_ps_top'
   ```
   BD 的模块引用是**建工程那一刻**生成的，重置子 run 不会重新生成。

**判据必须落在最终命令上**，不能信中间那句"设置成功" ——
所以新加的流程自检直接打 `WARN: ... core OOC directive NOT set`，
并且要求复查 `ps_pl_u_rv32_ps_0_synth_1/runme.log` 里 `Command: synth_design` 那行。

### 结论：剩下的是一个**架构决定**，不是工具参数

关键路径是工程在选 40 MHz 时就写明的那条：

> FCLK_CLK0 配 40MHz …… 路径在核内部：EX/MEM → 前递 mux →
> **M 扩展乘法器（2 个 DSP48E1 级联 + 进位链）** → EX/MEM
> …… **想把频率提回去，前提是先结构性缩短乘法器那条路径**

09-20 同一条路 22.441 ns（布线 11.8）→ 现在 25.404 ns（**布线 14.31，逻辑几乎没变**）。
**要过零就得动乘法器的微架构**（多拍乘法 / 加重流水），而那会改 ISA 时序、
动到核的转发与冒险逻辑 —— 按 `CLAUDE.md`「真正需要用户拍板的只有改控制律/改架构这类决定」，
**这一步停下来问，不自己动。**

---

**还欠的（按价值排序）**

1. **剩下 4 个 impl strategy 的复测**。`create_zynq_project.tcl` 自己写着这笔账：
   `NetDelay_high / ExplorePostRoutePhysOpt / Explore / RefinePlacement / ExtraTimingOpt`
   这 5 个是 **50 MHz 裸 PL 口径**下比的，却按名字搬到了 40 MHz 的 Zynq 工程上。
   这次补了 `RefinePlacement`（−2.822，与当年方向一致），**还剩 3 个没量**。
   每个约 35 分钟 —— **这是唯一还没试过、且不需要动 RTL 的杠杆**。
2. **核的存储器应答协议**。最后 0.604 ns 的形状是
   `payload → dmem_req → SoC 译码 → dmem_ready → dmem_write → payload` 的组合闭环
   （`rv32_memory_stage.v` 里 `dmem_write_o` 直接依赖 `dmem_ready_i`）。
   要收掉得改成多拍应答 —— **那是核的架构改动**，按 `CLAUDE.md` 属于要用户拍板的那类。

**复现/指纹**
- **`place`/`route` 能跑完但 `report_timing_summary` 报 `Timing constraints are not met`**
  ⇒ 这是**第四道关**（TB 全绿 ≠ 能综合 ≠ 装得下 ≠ 时序收敛），别和前三道混。
- **看 WNS 不够，必须看 TNS 和失效端点数**：WNS 只告诉你"最差的那条有多差"，
  TNS/端点数才告诉你"面有多大"。这次 WNS 只从 −6.5 改善到 −4.4，
  而**端点数掉了 15.5 倍** —— 只盯 WNS 会以为白干。
- **最差 N 条路径按模块归类**，别用 top10 下结论。
