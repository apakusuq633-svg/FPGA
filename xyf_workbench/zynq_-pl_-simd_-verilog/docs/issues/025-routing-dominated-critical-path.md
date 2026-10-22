# 025 关键路径 57% 是布线 ⇒ 布线后再补一遍 phys_opt

**症状** [023](../archive/issues/023-anc-coefficient-pipeline-timing.md) 修完 ANC 之后，40 MHz 仍 **WNS = −0.413 ns / TNS = −4.603 / 25 个端点失效**。
新的最差路径：`u_regs/halt_q` → 核 `u_ex_mem_reg` payload。

**误判**
1. 先归因于**扇出**——`halt_q` 和 `soft_rst_pulse` 都是扇到整个核的控制信号。**量了，不是**：
   ```
   INFO: [Physopt 32-65] No nets found for high-fanout optimization.
   | Very High Fanout | 0 |
   ```
   phys_opt 已经跑过扇出优化阶段（4/38/12 个候选网），工具判定没有超高扇出网。
2. 又想换 strategy/指令 —— 但笔记里已有的负结果（默认 −0.294 / Explore −0.439…）
   是**裸 PL 工程**上的，**Zynq 这边根本没量过**。这正是"拿一个口径的结论套另一个口径"。

**根因** 路径构成实测：

```
Data Path Delay: 24.907ns  (logic 10.626 (42.7%) + route 14.281 (57.3%))
Logic Levels: 28  (CARRY4=6 DSP48E1=2 LUT6=12 ...)
```

**57.3% 是布线**，逻辑 28 级只占 10.6 ns（0.38 ns/级，完全正常）。
所以是**摆位**问题：源在 SoC 边缘的 `rv32_ps_regs`，目的在核深处，两端离得远。

**修法** 在**已布线完成的网表上**再跑一遍 `phys_opt_design` + `route_design`，写进
`build/run_pl_flow.tcl`。实测：

| | 修前 | 修后 |
|---|---|---|
| WNS | −0.413 | **+0.094** |
| TNS | −4.603 | **0.000** |
| 失效端点 | 25 | **0** |

**⚠ 三个必须一起说的**：
1. **只测到 `Default` 一个指令**。`ExplorePostRoutePhysOpt` 报"不是 phys_opt 的合法指令"
   （那是 `place_design` 的）；`AggressiveExplore` 因为第一遍已把 WNS 修到 ≥0 而被
   `Skipping all physical synthesis optimizations` 直接跳过 —— **那两条都没真正跑过，
   不能当成"等价"**。
2. **余量只有 +0.094 ns**（25 ns 周期的 0.4%）。够 MET，但**没有抗环境变化的裕量**，
   汇报时按这个数写，不许写"余量充足"。
3. 第一次是**会话内增量**跑的，没存盘。已固化进流程并重跑，**以那次为准**。

**状态** ✅ **已修（复现）**：固化进 `build/run_pl_flow.tcl` 后完整重跑，**WNS = +0.094 / WHS = +0.017，与增量那趟逐位相同**，`write_bitstream completed successfully`（`build/rv32_zynq.bit`，2,083,849 字节）。

**复现/指纹** **关键路径的布线占比 > 50% 就是摆位问题，不是逻辑深度、不是扇出。**
判据：先看 `route/(logic+route)`；再看 `Logic Levels` 与逻辑时延的比值
（这里 0.38 ns/级，说明逻辑本身很健康）。这两个数一摆，就不用去猜扇出和策略了。
