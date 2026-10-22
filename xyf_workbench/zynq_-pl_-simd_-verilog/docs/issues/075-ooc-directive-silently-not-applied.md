# 075 核的 OOC 综合 directive **静默没生效** ⇒ 整个流程带着默认口径跑完 40 分钟

**日期**：2026-10-05
**状态**：**已修**（脚本 3 处：`-scripts_only` 建 run + `reset_run` 子 run + 两道自检。
实测 `runme.log` 里已是 `synth_design ... -directive PerformanceOptimized -mode out_of_context`；
**修完复核：directive 确实生效了，但数字一位没动** —— 见 §6）。
**相关**：[057](057-first-real-timing-measurement.md)（时序数字第一次落地）、
[074](074-local-vitis-ps7init-stale.md)（同一天、同一个"以为对其实没对上"的家族）、
`scripts/run_zynq_flow.tcl`、`docs/measurements.md` §2

---

## 1. 症状

本机重跑 `run_zynq_flow.tcl` 全流程，一切"看起来正常"——`SYNTH_OK` / `IMPL_OK` / `BIT_OK` / `FLOW_PASS`
全部打印，位流也出来了、还能上板跑通。**只有把数字跟台账对一下时才露馅**：

| | 本次跑出 | `docs/measurements.md` §2 记的产品口径 |
|---|---|---|
| WNS | **+0.461 ns** | +0.726 ns |
| WHS | **+0.023 ns** | +0.037 ns |
| Slice LUTs | **21968 = 41.29%** | 22065 = 41.5% |
| 端点 | 47159 | — |

而 `run_zynq_flow.tcl` 从头到尾**没报一个错**，日志里那行还是
`==> \[flow\] core OOC directive = PerformanceOptimized`（**读得到！**）。
§4 说"两套 Vivado 配置口径不同，时序结论不能互推" ⇒ 这次跑的其实是**默认口径**，当场不能认定它就是产品口径（后来查明本设计要求下两者数字相同，见 §6）。

## 2. 误判

- **以为 `set_property` 返回成功就等于生效**。它确实返回成功，`get_property` 也读得到
  `PerformanceOptimized` —— 但那是**run 对象的属性**，不是**已经生成的脚本**的内容。
- **以为 `generate_target all <bd>` 能把 OOC 子 run 建出来**。命令跑完了（`Time (s): cpu = 00:00:09`），
  `get_runs` 依旧为空。
- **以为 `create_ip_run [get_ips]` 是正路**。`get_ips -quiet` 确实返回
  `ps_pl_rst_u_ps7_40M_0 ps_pl_u_ps7_0 ps_pl_u_ps7_axi_periph_0 ps_pl_u_rv32_ps_0`，
  于是这段"看着很合理" —— 实际每个都报
  `ERROR: [Vivado 12-3424] IPI cores may not be directly generated or have a netlist
  directly created from it ... only through their block diagram`。
- ⚠ **第一版探测脚本把错误吞了**（`catch {...} e` 不打 `$e`），于是"为什么没建出来"一个字都看不到
  ——同 [070](070-fw-tb-maxc-stale-after-new-kernel.md) 那条教训：**命令必须有能力说出失败的原因**。

## 3. 根因

**三层叠加，缺一层都不会出这个现象**：

1. **时机**：BD 的 OOC 子 run（`ps_pl_u_rv32_ps_0_synth_1` 等）**只在 `launch_runs` 那一刻**由 Vivado
   连带创建（实证：`build/zynq_flow.log` 那行 `Launched ps_pl_u_ps7_0_synth_1,
   ps_pl_u_rv32_ps_0_synth_1, ...`）。脚本第 1b 段在 `source create_zynq_project.tcl` 之后立刻
   `get_runs`，**冷建时必然为空** ⇒ 原代码只 WARN 一句就往下走。
2. **`set_property` 不改已生成的脚本**：建 run 那步（`-scripts_only`）已经按**当时的**参数
   生成了 `ps_pl_u_rv32_ps_0.tcl`。之后改属性，脚本**不会跟着变**。
3. **顶层 `reset_run synth_1` 不连带动子 run**：脚本第 2 步那句 reset 只清顶层，子 run 的旧脚本
   原样留着 ⇒ `launch_runs` 照旧用旧脚本。

⇒ 结果就是 **set_property 成功 + 脚本没变 + 命令没带 directive**，
一个**不报错**的静默失效。

## 4. 修法

`scripts/run_zynq_flow.tcl` 第 1b 段改成：

```tcl
set core_run ps_pl_u_rv32_ps_0_synth_1
set core_ooc [get_runs -quiet $core_run]
if {$core_ooc eq ""} {
    # ① 用 -scripts_only 建 run（只创建 + 生成脚本，**不跑综合**）。实测有效。
    launch_runs synth_1 -scripts_only
    set core_ooc [get_runs -quiet $core_run]
}
if {$core_ooc eq ""} { puts "FLOW_FAIL: ..."; exit 1 }        # ② 建不出就立即退出
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized $core_ooc
reset_run $core_ooc                                          # ③ 删掉旧脚本，逼它按新属性重建
```

外加**两道自检**（把注释里的"判据"变成脚本会执行的检查）：

- 第 1b 段建不出 run → `FLOW_FAIL` **立即退出**（原来只 WARN，白跑 40 分钟）；
- `SYNTH_OK` 之后读核的 `runme.log`，`regexp` 找 `Command: synth_design ... -directive (\S+)`，
  **找不到就 FLOW_FAIL**。这条是这次能当场发现问题的关键。

实测顺序（每一步都验过）：

| 做法 | 结果 |
|---|---|
| `generate_target all <bd>` | 跑了，`get_runs` 依旧空 ✗ |
| `create_ip_run [get_ips]` | 全部报 `[Vivado 12-3424]` ✗ |
| **`launch_runs synth_1 -scripts_only`** | **建出全部 5 个 OOC 子 run** ✓ |
| 只 `set_property` 不 reset | 属性读得到，`runme.log` 里**没有** `-directive` ✗ |
| **`set_property` + `reset_run <子run>`** | **`runme.log` 里 `-directive PerformanceOptimized`** ✓ |
| `reset_run synth_1`（顶层）会不会清掉 directive | **不会**（实测子 run 与 directive 都还在） |
| `reset_run <子run>` 会不会删掉 run | 不会；但会**删掉它生成的 `.tcl`**，launch 时重建 ← 这正是起作用的原因 |

## 5. 复现指纹

**判据一行**（跑完流程后看核的 `runme.log` 第 13 行附近）：

```bash
grep "Command: synth_design" \
  vivado_zynq/rv32_zynq.runs/ps_pl_u_rv32_ps_0_synth_1/runme.log
```

- 对：`synth_design -top ps_pl_u_rv32_ps_0 -part xc7z020clg400-1 **-directive PerformanceOptimized** -mode out_of_context`
- 错：`synth_design -top ps_pl_u_rv32_ps_0 -part xc7z020clg400-1 -mode out_of_context`

**辅助指纹**：整套流程 `wait_on_run synth_1` 只花 **2 分 59 秒** —— 子 run 没重跑。
真跑了（带 directive）时核那一段要久得多。

⚠ **别再信这三样**：`set_property` 的返回、`get_property` 的读数、
`==> \[flow\] core OOC directive = ...` 那行日志 —— **三者都会在没生效时照样显示成功**。
唯一可信的是 `runme.log` 里那行实际执行的命令。

---

## 6. 修完之后的复核（2026-10-05 晚）—— directive 生效了，**数字一位没动**

按同一脚本重跑（`build/zynq_flow_rerun.log`，15:57 → 16:16，约 19 分钟；比坏的那次 2:59 长得多，
说明核确实重跑了）。自检通过，`runme.log` 第 13 行确实带上：

```
Command: synth_design -top ps_pl_u_rv32_ps_0 -part xc7z020clg400-1 -directive PerformanceOptimized -mode out_of_context
```

**但结果与修之前那一次逐位相同**：

| | 修之前（默认口径） | 修之后（`PerformanceOptimized`） |
|---|---|---|
| WNS / WHS | +0.461 / +0.023 | **+0.461 / +0.023** |
| LUT | 21,968 | **21,968** |

⇒ **`PerformanceOptimized` 对这个核实测是 no-op**（同一份 RTL、同一台机器，两次跑完全一致）。

**这条否掉了本 issue 原先的暗示**（§1 那张"对不上台账"的表容易被读成"差在 directive"）：

- **10-04 的 +0.726 不是被这条 directive 决定的。** 那次脚本里 `set_property` 外面只有 WARN 守卫、
  且没有 `reset_run`（`git show HEAD:scripts/run_zynq_flow.tcl`）⇒ 跑的就是默认口径；
  而本机默认口径给的是 **+0.461**。
- 0.265 ns 的跨机器差是**另一件事**，记在 `docs/measurements.md` §2，**本 issue 不管**。

**§4 修的是"口径可保证"，不是"数字会变"。** 这条修复照样必须留着 ——
它把"跑出来的数是不是产品口径"从**碰运气**变成**脚本自证**：
现在核的 `runme.log` 里没有 `-directive`，流程就 `FLOW_FAIL` 退出，不会再白跑 40 分钟拿到一组口径不明的数。
