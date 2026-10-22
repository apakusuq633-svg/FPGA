# 064 `run_board.tcl` 卡在"先要 APU 才能复位"，而复位正是让 APU 出现的那一步

> ## ⚠ 2026-10-04 晚些时候的更正：本文的**归因**很可能是错的
>
> 本文把「重上电后 APU 短暂缺失」归因成 `run_board.tcl` 的**顺序问题**（先选 APU 才复位）。
> 但当天稍后查清了**真正的并发原因**：**另一个项目在同一块板子上跑 XSCT**
> （见 [065](065-shared-jtag-two-projects.md)）。对方执行 `rst -system` 时，
> **我们这边的目标列表里 APU 就会消失** —— 这**完全能独立解释**本文观察到的现象。
>
> ⇒ 所以：**"APU 不在"首先要排除的是"别人正在复位板子"**，而不是先改自己的复位顺序。
> 本文那条绕法（先 `targets 1` 选 DAP 再 `rst -system`）**本身无害、可以留着用**，
> 但它治的是症状不是根因。**判据见 065。**
>
> 保留原文是因为"顺序确实有先有鸡先有蛋的形态"这一点仍然成立，
> 值得后来者知道；但**不要**据此认为板子或脚本有这个固有缺陷。

**日期**：2026-10-04
**状态**：**已定位，脚本已绕开**（新增 `scripts/probe_ps_recover.tcl`）；板子当前另有故障，见 §5
**相关**：`scripts/run_board.tcl`、`docs/board_io.md`

---

## 1. 症状

板子重新上电/复位之后跑 `xsct scripts/run_board.tcl -app rv32_app`：

```
xsct.bat : no targets found with "name =~ "APU"". available targets:
  1  DAP (AHB AP transaction error, DAP status 0x30000021)
  2  xc7z020
    while executing
"targets -set -filter {name =~ "APU"}"
    (file "scripts\run_board.tcl" line 27)
```

**JTAG 链是通的**（`xc7z020` 在、DAP 在），只有 A9 那两个核不在。

## 2. 根因：先有鸡还是先有蛋

`run_board.tcl` 的顺序是：

```
connect
targets -set -filter {name =~ "APU"}     ← line 27：**先要 APU**
rst -system                              ← line 28：而这一步才是让 APU 出来的
```

板子刚上电时 A9 **短暂不在链上**，于是卡在第 27 行，
**第 28 行的复位从来没执行过** —— 而复位恰恰是能让 A9 出来的那一步。
两个失败互相锁死。

## 3. 绕法

`scripts/probe_ps_recover.tcl`：**先选中 DAP（`targets 1`）再 `rst -system`**，
再等 A9 起来。实测：

```
复位前: 1 DAP / 2 xc7z020
复位后: 1* DAP / 3 ARM Cortex-A9 MPCore #0 (Running) / 4 ARM Cortex-A9 MPCore ...
PS_RECOVER_OK: 找到 Cortex-A9
```

跑完这个再跑 `run_board.tcl` 就通了 ✓。

⚠ **`targets <名字>` 不行** —— 它要的是**数字 id**。传名字报
`no target with id: DAP`，看着像"没这个目标"，其实是参数形式错了。
`targets` 列表里每项第一行的那个数才是 id。

## 4. 顺带发现：`ps7_init` 会因为 A9 在跑而失败

如果跳过复位直接 `ps7_init`：

```
Memory read error at 0xF8007080. Cannot access virtual memory. Execution context is running
```

原因是 A9 还跑着上一个 app（`Execution context is running`），
DAP 读不进去。**看着像 ps7_init 坏了，其实是没复位。**
⇒ **`rst -system` 必须无条件执行**，不能在"APU 已经在"时自作聪明地跳过。

## 5. 当前板子的另一个故障（**未解决，需要人**）

绕开第 2 节那个坑之后，DAP 又反复进错误态：

```
Cannot reset DAP. AP transaction error, DAP status 0x30000021
```

- 已排除：僵尸 `hw_server`/`xsct`/`vivado` 进程（查过，一个都没有）
- 已排除：脚本问题（换 `probe_ps_recover.tcl` / `probe_core_alive.tcl` 都一样）
- **`xi7z020` 一直在链上**，所以 JTAG **排线**大概率没断

⇒ 判断是需要**真的断电重上电**（不是按复位键）。可能原因：供电不足 / 启动模式跳线 /
PS 被别的状态按住。

## 6. 复现指纹

- **`no targets found with "name =~ "APU""` 且列出的目标里只有 DAP + xc7z020**
  ⇒ 先跑 `probe_ps_recover.tcl`（选 DAP → `rst -system`），不要改 RTL、不要怀疑位流。
- **`Cannot access virtual memory. Execution context is running` 出现在 `ps7_init` 里**
  ⇒ A9 没被复位，不是 `ps7_init` 的问题。
- **`Cannot reset DAP ... 0x30000021`** ⇒ 脚本已经无能为力，去动板子。
