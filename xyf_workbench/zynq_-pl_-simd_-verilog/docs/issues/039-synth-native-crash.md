# 039 `synth_design` 原生崩溃（0xC0000005）—— 连 4 行 blink 都崩

**状态**：**已修**（2026-10-01，用户卸掉联想预装的那套软件之后）。

**结案实测**（`scripts/probe_vivado_sanity.tcl`，就是下面那个 4 行 blink 探针）：

```
S0 vivado 版本 : 2020.2
S1 create_project = OK
S2 已写出 4 行 blink
Synthesis finished with 0 errors, 0 critical warnings and 0 warnings.
S3 synth_design = OK
S4 模块数 = 44
PASS: blink 综合完成且 Tcl 层没崩 ⇒ 综合流程可用
```

退出码 0，**没有 `TclStackFree`**。判据是当年自己定的那条
（「只要 `synth_design` 能在一个 4 行的 blink 上跑完，这一步就通了」），够干脆。

⚠ **严格说只动了一个变量**：用户卸掉的是"联想预装的整套软件"，不只是火绒。
所以下面那条"火绒注入"的推测**仍未单独证实** —— 但它作为**方向**是对的：
问题在环境，不在我们的 RTL。这和 037/038 那两条（会指名 RTL 文件行号的
`ERROR: [Synth 8-xxxx]`）从一开始就不是一类东西。

**代价**：从 2026-09-21 到 2026-10-01，整整十天里
**这个仓库没有任何真实的时序或资源数字**，所有综合结论都是"跑不了"。
现在解除了，见 `scripts/run_zynq_flow.tcl`（本档案下面"对引脚验证的影响"那节
说的 `report_io` 那一步，就是它第 5 段做的）。

**症状** `launch_runs synth_1` 永远到不了 100%。批处理日志里**没有 ERROR**，
只有一句 `WARNING: [Vivado 12-8222] Failed run(s) : 'synth_1'`。
真正的死在 run 自己的日志 `vivado/rv32_pipeline.runs/synth_1/runme.log` 末尾：

```
INFO: [Synth 8-6155] done synthesizing module 'rv32_board_top' (45#1) ...
TclStackFree: incorrect freePtr. Call out of sequence?
```

**45 个模块全部综合完成**，然后进程在 Tcl 层崩掉。退出码 `-1073741819`
= `0xC0000005` = **ACCESS_VIOLATION**（原生段错误）。

**误判** 第一反应是「又是我们的 RTL」——毕竟同一个文件里刚查出两个真 RTL 问题
（[037](037-synth-rejects-sv-for-loop.md)、[038](038-readmemh-relative-path-empty-rom.md)）。
但这次的**标志不同**：那两个是 `ERROR: [Synth 8-xxxx]`，**会指名 RTL 文件和行号**；
这次一条 RTL 相关的 ERROR 都没有，而且崩在**所有模块都综合完之后**的 Tcl 阶段。

**根因** **与我们的设计无关** —— 用一个最小实验切开了：

`build/probe_vivado_sanity.tcl`，4 行 blink、纯 ASCII 路径 `C:/vivado_sanity`、
空工程、与仓库没有任何关系：

| 动作 | 结果 |
|---|---|
| `create_project` | OK |
| `create_bd_design` | OK |
| **`synth_design -top blink`** | **崩**，进程退出码 `-1073741819` |

**连 4 行 blink 都综合不了 ⇒ 是这台机器上的 Vivado 坏了，不是我们的工程。**

旁证（同样是原生崩溃，但没有量到因果，只作参考）：
`%APPDATA%\Xilinx\Vivado\` 下留着两份 JVM 崩溃日志 `hs_err_pid26812.log` /
`hs_err_pid31980.log`，分别是 `librdi_common.dll`（Vivado 的数据库层）里的
ACCESS_VIOLATION 和 `KERNELBASE.dll` 里的未捕获 C++ 异常。

**已排除的**：显卡/磁盘？不是 —— NVMe SSD；**硬件**？不是 —— 14 天内
`Microsoft-Windows-WHEA-Logger` **一条事件都没有**；页面文件/空间？不是 ——
D: 剩 340 GB。

**嫌疑最大的一条（未证实）**：这台机器装着**第三方杀软
「Lenovo Anti-Virus powered by Huorong Security」**（火绒，另有 Windows Defender）。
杀软往大进程里注入 DLL / 挂文件过滤驱动，是
「`TclStackFree` 栈被破坏 + librdi_common 里 ACCESS_VIOLATION」的经典成因。
**这条是推测，我没有量到，不要当结论用。**

**修法（需要用户拍板）** 改杀软设置属于**对本机安全设置的改动**，我没有擅自做。
建议按顺序试：

1. 把 `D:\Vivado` 与仓库目录加进火绒的**排除/信任区**，重跑
   `build/vfft_timing_bare.tcl`
2. 不行就**临时停用**火绒（含 Windows Defender 实时防护）再重跑一次
3. 仍然崩 ⇒ 修 Vivado 安装（`vivado.bat` 有 repair 选项）

**判据很干脆**：只要 `synth_design` 能在一个 4 行的 blink 上跑完，
这一步就通了。**先用 blink 试，不要拿我们的工程去试** —— 那样分不清是
杀软治好了还是本来就没触发。

**复现指纹** 综合"跑完但 run 失败"，批处理日志无 ERROR，runme.log 末尾是
`TclStackFree: incorrect freePtr` 且退出码 `-1073741819` ⇒ **先怀疑环境/杀软，
别改 RTL**。这与 [018](018-vivado-bd-flow-environment.md) 是同一族的
"errno/现象与软件行为矛盾"。

---

## 补记 2026-09-24：`run_zynq_flow.ps1` 会把它误判成 BD 偶发，白重试 6 次

Zynq 流程复跑时又撞上它，这次的现场值得记一笔。

**症状换了个位置出现**：不再是自己工程的 `synth_1`，而是 BD 里那几个 IP 的 OOC run。
批处理日志（`build/vfft_timing.log`）里只有：

```
WARNING: [Vivado 12-8222] Failed run(s) : 'ps_pl_rst_u_ps7_40M_0_synth_1', 'ps_pl_u_ps7_0_synth_1'
!! synth_1 did not reach 100%
```

**四个 IP run 全部崩了**（`Get-ChildItem ... -Filter runme.log | Select-String TclStackFree`
命中 `ps_pl_auto_pc_0` / `ps_pl_rst_u_ps7_40M_0` / `ps_pl_u_ps7_0` / `ps_pl_u_rv32_ps_0`），
每个的最后一行都是 `TclStackFree: incorrect freePtr. Call out of sequence?`，
而且**崩之前所有模块都综合成功了**（`done synthesizing module 'ps_pl_u_ps7_0'`）——
与本档案开头记的完全同型。**不是引脚改动引起的**（那次改动只动了 tacho 的 `PACKAGE_PIN`）。

**脚本的缺陷**：`run_zynq_flow.ps1` 的 `$hardErr` 找的是 `^ERROR: \[(Synth|...)`，
而原生崩溃**一条 ERROR 都不打**。于是它落到「BD init flaked」分支，把 6 次重试全用完
（约 20 分钟）才放弃 —— 正是该脚本注释里写明要避免的
「把一个真 bug 报成环境问题」。

**修法（已做）**：在 `$bdFlake`/`$hardErr` 之前加一道 039 专属判据 ——
批处理日志里有 `did not reach 100%`，再去子 run 的 `runme.log` 里找 `TclStackFree`；
命中就立刻 `exit 1` 并打印"这是 issues/039，环境问题，重试无用"。
判据已在真实日志上验证成立（`did not reach 100%` 2 处、`TclStackFree` 4 个 runme.log）。

**对引脚验证的影响**：`ps_pl_wrapper.xdc` 的 R18 约束**无法在本机走完综合验到**。
能验到的到此为止：

- `scripts/check_pins.tcl` —— 器件数据层（`link_design` + `get_package_pins`），
  R18 = `IO_L20N_T3_34`，**与 039 无关，可跑**。
  ⚠ 这是**本机唯一能跑通 Vivado 的那类脚本**：它只查器件数据、不碰
  `synth_design`。换 7020 时的 7010/7020 逐脚对比就是靠它做的
  （19/19 同脚，见 [050](050-pincheck-vacuous-pass.md)）。
  原路径在 `build/`（gitignored），已挪到 `scripts/` 免得被清掉
- `create_zynq_project.tcl` 的三段端口自检全过，含新加的
  `==> tacho wrapper port OK: 1 input`
- 批处理日志里 **0 条 `No ports matched`** ⇒ `PACKAGE_PIN R18 ... [get_ports tacho_i]`
  确实匹配到了端口，不是静默失效

剩下那一层（综合后 `report_io` 读出实际 site）**必须等 039 修好**。判据同上：
先让 4 行 blink 能综合完。

**同日复测 blink（`build/probe_vivado_sanity.tcl`，`build/probe_sanity.log`）**：

```
S1 create_project = OK
S1 A: create_bd_design = BD_OK          ← 018 那个 BD 问题这次没有复现
S1 B: synth_design
    INFO: done synthesizing module 'blink' (1#1) ...
TclStackFree: incorrect freePtr. Call out of sequence?
Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)   (hs_err_pid14256.log)
```

三条结论：

1. **039 仍然成立**，而且是**当前唯一**挡在综合前面的东西。4 行 blink、纯 ASCII 路径
   `C:/vivado_sanity`、空工程 —— 与仓库无关。
2. **它下方还有多少东西被挡住**：`report_io` 验引脚、出位流、以及全部上板测试
   （`scripts/test_tacho.tcl` 需要有位流），**都要等它**。
3. **与 018 分离了**：这次 `create_bd_design` 是好的。所以 018 的 BD 那条是间歇性的，
   而 039 是稳定的 —— 两者虽然同族，但**不要再用 018 的重试去盖 039**。

