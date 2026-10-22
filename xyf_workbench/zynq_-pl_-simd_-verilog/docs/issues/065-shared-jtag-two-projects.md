# 065 「板子坏了」其实是**两个项目在抢同一块板子的 JTAG**

**日期**：2026-10-04
**状态**：**已定位；已加守卫**（争用本身要两个团队协调，软件消不掉）
**相关**：[064](064-run-board-apu-chicken-and-egg.md)（另一个上板坑）、
`docs/board_io.md`、`scripts/check_jtag_owner.ps1`

---

## 1. 症状：所有现象都指向"板子坏了"

上板时报的是一串看起来像**硬件损坏**的东西：

```
Cannot reset DAP. AP transaction error, DAP status 0x30000021
no targets found with "name =~ "APU"". available targets:
  1  DAP (AHB AP transaction error, DAP status 0x30000021)
  2  xc7z020
`targets` 直接卡死不返回
```

- **断电重上电有时能好、有时不能** ⇒ 更像硬件
- 重上电之后**跑一次就再坏** ⇒ 我当时据此认定"跑 A9 app 会弄坏 DAP"
- 串口收不到任何字节 ⇒ "app 没跑起来"

## 2. 误判（**这条最值得记**）

我由"重上电 → 跑 app → 又坏"这个**时间顺序**，推出「**跑 A9 app 会把 DAP 弄坏**」，
并为此写了两个探针去"绕开"和"二分"这个所谓的原因（`probe_core_by_jtag.tcl`
的前身、`probe_dap_bisect.tcl`）。

**那个结论是错的。** 真正发生的是：

| 时刻 | 我们 | 另一个项目 |
|---|---|---|
| A | 跑 `test_pdm_onboard.tcl` ✓ | 空闲 ⇒ **成功** |
| B | 跑 `probe_core_alive.tcl` ✗ | **正好也在访问** ⇒ **失败** |

**我把时间上的巧合当成了因果。** 判据本来就有：如果是"app 弄坏 DAP"，
那么"只下位流 + `ps7_init`"这条路**跑多少次都该没事** —— 而它确实跑了很多次都没事，
我却没有反向去问"**失败那几次，有没有别的东西同时在动**"。

> **教训**：**并发故障要先排除"还有谁在用"**，而不是先假设"我这步做了什么坏事"。
> 这条仓库 §0 的「改之前先量」管不到 —— 因为要量的是**别人**，不是我的代码。

## 3. 根因

**这台机器上有两个项目，共用同一块板子**：

```
本项目    D:\Users\xyfhhh\Desktop\PDM\zynq_-pl_-simd_-verilog                （PDM）
另一个    D:\Users\xyfhhh\Desktop\multichannel_acoustic\zynq_-pl_-simd_-verilog（I2S）
```

抓到的证据：

```
PID 6660  rdi_xsct.exe
  ...\multichannel_acoustic\zynq_-pl_-simd_-verilog\build\_dapcheck.tcl
```

对方那份脚本的内容是 `connect` / `puts "TARGETS: [targets]"` / `disconnect` ——
**和我们跑的一模一样，因为他们也在被我们破坏，也以为板子坏了。**

**机制**：先起的那个占住 `TCP:3121` 的 `hw_server`，后起的 XSCT **直接复用**它
⇒ **两条 XSCT 同时驱动同一个 JTAG 适配器** ⇒ DAP 互相踩。

**为什么"重上电有时管用"**：断电重来会杀掉两边所有会话，谁先跑谁干净一会儿 ——
纯粹是**时间窗口**，不是电的问题。

## 4. 第二个坑（我自己造成的）：僵尸 `hw_server` 占死设备

排查过程中我 `TaskStop` 掉了几次卡住的连接，留下了：

```
hw_server.exe  PID 35560  start=12:00:34
```

它卡在驱动调用里：`taskkill` 报 "no running instance"、`HasExited=True`，
但**进程和 3121 端口都还在**。判定它是**设备句柄占死**的，用的是这一条：
**另起一个 hw_server 到别的端口（3122）→ 新服务器能监听 ✓，但 `targets` 照样卡死 ✗**
⇒ 不是"服务器卡住"，是"设备被占住"。

它最后**自己消失了**（约半小时后，旧会话彻底超时）⇒ 之后一次跑就全绿了：

```
RETIRE_CNT: 4651198 -> 45476291   （1 秒退休 4082 万条指令）
TRAP_CNT  : 0
CORE_ALIVE ✓
```

## 5. 修法与守卫

**争用本身软件消不掉** —— 对方什么时候启动是随机的，只能约定时段。但可以**不再误判**：

- **`scripts/check_jtag_owner.ps1`**：按**命令行里的路径**判断。
  ⚠ **看进程名没用** —— 两边的可执行文件都叫 `rdi_xsct.exe` / `hw_server.exe`。
  （保持纯 ASCII：PowerShell 5.1 按系统代码页解码无 BOM 的 .ps1，非 ASCII 会解坏。）
- **`scripts/jtag_guard.tcl`**：已接进 `run_board.tcl` / `test_pdm_onboard.tcl` /
  `probe_ps_recover.tcl` / `probe_core_alive.tcl`，**在 `connect` 之前**先查，
  被占就拒绝并打印判据，而不是卡死让人误判。
- **`scripts/probe_jtag_fresh.tcl`**：换端口判定"设备被占死"还是"服务器卡住"。

## 6. 复现指纹

- **`Cannot reset DAP ... 0x30000021` / `targets` 卡死 / 上电后时好时坏**
  ⇒ **先查有没有别的项目在用这块板子**（`scripts/check_jtag_owner.ps1`），
  **不要先怀疑板子、更不要先怀疑自己的 RTL**。
- **`taskkill` 报 "no running instance" 但进程还在、端口还占着**
  ⇒ 卡在驱动里的僵尸。**换端口起一个新 hw_server 试试**：能监听但扫不到目标 ⇒
  设备句柄被占死；等旧会话超时、或拔插那根 USB（**板子不用断电**）。
- **`Already stopped` / `Execution context is running`** ⇒ 这两个是**良性**的
  （`rst`/`stop`/`mrd` 对已停或正在跑的目标），包 `catch` 继续，别让它们带停脚本。
