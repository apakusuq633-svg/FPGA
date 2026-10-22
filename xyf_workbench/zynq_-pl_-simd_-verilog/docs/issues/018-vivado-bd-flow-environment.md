# 018 BD 流程失败其实是环境问题

**症状** `create_zynq_project.tcl` 在 `create_bd_design` 报：

```
couldn't read file "D:/Vivado/.../rsb/design_assist/conn/axi4/rules.tcl": No error
ERROR: [Ip 78-90] Error in initialization of Rule object 'xilinx.com:bd_rule:axi4:1.0'
```

**误判** "Vivado 装坏了"。但那个 `rules.tcl` **是存在的**（65 KB），
而且 `No error` 这个 errno 本身就矛盾 —— 读不到文件不该是"No error"。

**根因** 两个环境因素叠加：
1. 从 **Git Bash** 调 `vivado.bat` —— `HOME` 被改成 `/c/Users/xyfhhh` 这种 Unix 路径，
   Vivado 的 IP rule 加载器解析不了。
2. 机器上**同时有两个 `vivado.exe` 在跑**（另有一条裸 PL 流程），抢 IP design_assist。

**修法** 从 **PowerShell**、干净环境、确认没有别的 Vivado 在跑，再重跑。
`ps_pl.bd` 从 **320 字节空壳**变成 **55872 字节真 BD**，一次成功。**不用重装。**

**副作用（我造成的）** 失败那趟把 `vivado_zynq/.../ps_pl.bd` 写成了 320 字节空壳，
而 `vivado_zynq/` 在 `.gitignore` 里、git 里没有备份。
好在这个 BD 是 **100% 脚本生成**的（`create_bd_design` + 每条 `create_bd_cell` 都是 Tcl），
重跑脚本就完整重建，**没丢手工成果**。
另一个后果：那个空壳会让 `check_ps_apps.py` 崩（`KeyError: 'components'`），
所以 `verify.ps1` 第 14 项会红 —— **红的原因是那个文件，不是代码**。

**复现/指纹** **errno 和现象矛盾时，先怀疑环境而不是软件。**
另外：**跑 Vivado 之前先 `Get-Process vivado`**，并发跑是这次的真凶之一。

---

## 第二次（2026-09-22）：同一个地方，换了张脸 —— 而且上面的修法**不够**

**症状** 加 VFFT 之后复跑 40 MHz 流程，同一个 `create_bd_design` 又挂，但报的是：

```
couldn't read file "replace_bd_cell.tcl": Illegal byte sequence
ERROR: [BD 41-68] Error sourcing TCL file
    (file "D:/Vivado/.../scripts/ipintegrator/init.tcl" line 14)
```

**误判** 第一反应是照 018 的修法查一遍 —— 但**这次本来就是从 PowerShell 跑的、
`Get-Process vivado` 事先确认过没有并发**（`HOME` 为空，没被改写成 Unix 路径）。
018 的两条成因这次一条都不成立。于是转去怀疑那个文件本身。

**排查（走了三步，前两步都是死路）**

1. 怀疑文件编码坏。量下来：**16624 字节、非 ASCII 字节数 = 0（纯 ASCII）**。
   纯 ASCII 在任何 ASCII 兼容编码下都读得进 ⇒ **不是文件的问题**。
2. 怀疑相对路径解析不了（`init.tcl` 第 14 行写的是光秃秃的 `replace_bd_cell.tcl`）。
   但**第 9~13 行同样是相对路径** source 了 `utils.tcl` / `mig_utils.tcl` /
   `board_utils.tcl` / `utils_dbg.tcl` / `clkrst.tcl`，全过了 ⇒ **不是路径的问题**。
   顺带排掉了「cwd 有中文」：那几个文件在同一个目录，要挂一起挂。
3. 写探针在 Vivado 自己的 Tcl 里读它（`build/probe_enc.tcl`）：
   ```
   PROBE enc_sys  = cp936        PROBE tcl = 8.5.14
   PROBE replace_bd_cell.tcl size=16624 read_ok chars=16624
   PROBE non_ascii = NONE (pure ASCII)
   PROBE source_ok          <-- 在探针里 source 得过
   ```
   **同一个文件、同一个解释器、同一台机器，探针里 source 成功。**

**根因** **至今没定位到。** 但有一条**已被证伪的中间结论**必须写下来。

> ⚠ 我中途写过「这是偶发，重跑就好」—— **那是错的，别信。**
> 依据是当时有一次重跑过了 `create_bd_design`。继续量下去后：
> **连着 9 次全挂，失败点是同一个文件**，而中间没有任何可控变量被改过。
> 这就是 CLAUDE.md §0 说的「先给结论、后想去量」，我在这里又犯了一次。

**已经排掉的（都是量过的，不是推的）**

| 猜的成因 | 怎么排除的 |
|---|---|
| 文件坏了 / 编码不对 | 报错文件 **非 ASCII 字节数 = 0**（纯 ASCII）；`[IO.File]::ReadAllBytes` 读得正常 |
| 相对路径解析不了 | `init.tcl` 第 9~13 行同样相对路径 source 别的文件全过；且报错里是**绝对路径** |
| cwd 含中文 | 那些过了的文件和挂了的是**同一个目录**。另有三个对照实验见下 |
| 并发 Vivado | 跑前 `Get-Process vivado` 确认过没有；018 第一条成因这次不成立 |
| 磁盘慢 / 空间不够 | **NVMe SSD**（`MediaType=SSD`）；D: 剩 340 GB |
| 工程目录陈旧（320 B 空壳） | **手工 `Remove-Item vivado_zynq -Recurse -Force` 清干净后照样挂** |
| 文件缺失 | 两次报错的文件都存在（16624 B / 510 B），目录布局与邻居 `clock_signal` 一致 |

**最关键的一个量**：`build/probe_busdef.tcl` 在**裸 Vivado** 里，把 BD 那一路**原样**跑了一遍 ——

```
P2 file_exists= 1     P2 file_size  = 510
P2 plain_read  = OK 510 chars
P2 ns_source   = OK      <-- namespace eval ::xilinx.com_signal_interrupt_1.0 { source ... }
```

**同一个文件、同一个解释器、同一条命令，在裸 Vivado 里成功，在
`create_bd_design` 里失败。** 所以变量不在文件、不在命令，在 **BD 初始化的上下文**里。

**三个对照实验（把"是不是路径的锅"彻底切开）**

| 实验 | 工程 | 路径 | `create_bd_design` |
|---|---|---|---|
| `build/probe_vivado_sanity.tcl` | 空工程 | **纯 ASCII** `C:/vivado_sanity` | **OK** |
| `build/probe_bd_cn.tcl` | 空工程 | **含中文**（本项目下） | **OK** |
| `build/probe_bd_incdir.tcl` | 空工程 + `include_dirs` 指向中文目录 | 含中文 | **OK** |

结论：**路径不是原因，`include_dirs` 里的中文也不是。**
空工程在两种路径下都建得出 BD，唯独**我们这份工程**连挂 9 次。
所以变量在 `create_zynq_project.tcl` 比空工程**多做的那几步**里
（`add_files` 40 个 RTL、`rv32_defines.vh` 的 Verilog Header 处理、
`update_compile_order`）—— **这几步还没逐个二分，是下次的起点**。

**一个旁证（不是因果）**：`%APPDATA%\Xilinx\Vivado\` 下留着两份 **JVM 原生崩溃日志**
（`hs_err_pid26812/31980.log`，`librdi_common.dll` 里 ACCESS_VIOLATION）。
**没有量到它与本问题相连，只作参考。**

---

## 状态（2026-10-04 更新）

**第二条从此再没复现过。** `build/zynq_flow6.log` ~ `zynq_flow13.log`
**连续 8 次** `create_bd_design` 全部一次通过（含最终那次时序闭合的 flow13）。

⇒ 它是个**偶发**，不是稳定故障。**根因仍未定位**，但：

- **不阻塞任何交付物** —— 位流、时序、上板都已经拿到（见 README 的时序行）。
- **不做二分的理由**：它复现不出来就没法验证二分的结果；按 §0「参数扫不动就是信号」，
  对着一个不复现的现象做二分，量到的只会是噪声。
- **真复现时从哪开始**：把 `create_zynq_project.tcl` 与空工程的差（`add_files` 40 个 RTL、
  `rv32_defines.vh` 的 Verilog Header 处理、`update_compile_order`）逐个二分 ——
  上面那三个对照实验已经把"路径 / 中文 / include_dirs"切开了，剩下的就是这几步。

> ⚠ 顺带修正本文开头那条修法的适用范围：**"从 PowerShell 跑、先查并发"是必要的，
> 但对第二次的失败不充分**（那次两条都不成立）。别把它当万能解。

**⚠ 但更重的一条是另一个问题**：同一轮排查里量出
**`synth_design` 连 4 行 blink 都原生崩溃（0xC0000005）** ——
见 [039](039-synth-native-crash.md)。**那条才是主拦路虎**：
就算这里把 BD 修好，综合照样崩，WNS 一样拿不到。

**修法（绕过，不是修好）** 走**裸 PL 流程**（`build/vfft_timing_bare.tcl`，
没有 PS、没有 BD，走不到 busdef 那条路）能**多走一大截** ——
它一路跑到综合完成，也正是在那里暴露出 037/038 两个真 RTL 缺陷。
**但 40 MHz 的 WNS 仍然拿不到**：既因为两套配置的时序结论不能互推
（CLAUDE.md §4），更因为综合本身崩（039）。

**没再往下做的原因**：再往下要么动 Vivado 安装，要么动本机杀软排除项 ——
后者是对**本机安全设置**的改动，得用户自己拍板。已把判据和排掉的分支留在这里，
下次接着查不用重走。

**复现指纹** `create_bd_design` 报 `couldn't read file "<Vivado 安装目录下的文件>":
<假 errno>`（见过 `Illegal byte sequence` 和 `no such file or directory` 两种），
**而那个文件确实存在、Windows 侧读得动** ⇒ 别再查文件和路径了，
那是 BD 初始化上下文的问题。先试裸 PL 流程拿资源，40 MHz 时序另行解决。
