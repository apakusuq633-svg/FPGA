# 066 A9 跑起 app 之后**停不下来**，PL 核也从没被放起来

**日期**：2026-10-04
**状态**：**已修**（2026-10-04）—— 根因见 [067](067-ddr-part-mismatch-4gb-vs-2gb.md)：
DDR 颗粒型号配错（写约 9% 丢掉），A9 取到坏指令后把 PS 互连同 DAP 一起锁死。
先是用「app 重链到 OCM」绕过（`PASS (0 failures)`，串口第一次有输出），
随后把 DDR 参数改对，**DDR 版 app 也端到端 `PASS`** —— 根因真正修好。
**本文第 2/3 节的排除过程与判据仍然有效，保留原样。**
**相关**：[065](065-shared-jtag-two-projects.md)（**先排除它** —— 板子被别的项目抢会伪装成各种症状）、
[067](067-ddr-part-mismatch-4gb-vs-2gb.md)（**根因**）、
`sw/ps_main.c`、`sw/lscript_ocm.ld`、`scripts/run_board.tcl`、`scripts/probe_a9_early.tcl`

---

## 1. 症状（实测，可复现）

跑 `xsct scripts/run_board.tcl -app rv32_app`（下位流 → `ps7_init` → `dow` → `con`）：

| 现象 | 观测 |
|---|---|
| **PS UART0 一个字节都没有** | `build/uart_*.log` 全是 0 字节（串口确实打开成功、波特率/引脚都对：UART0 在 MIO14-15、115200）|
| **A9 停不下来** | `stop` 报 `Cannot halt processor core, timeout` |
| **读内存报在跑** | `mrd` 报 `Cannot access virtual memory. Execution context is running` |
| **PL 核从没被放起来** | `CTRL = 0x00000002`（HALT=1，正是**软复位后的默认值**）、`RETIRE_CNT = 0`、`LED_STATE = 0` |
| **STATUS.ERR 置位** | `STATUS = 0x4`（RTL 注释：运行期写 TCM 被拒会置这一位）|

**`CTRL` 停在软复位默认值**这一条最关键：`sw/ps_main.c` 的流程是
「`CTRL=0x3`（START\|HALT）→ 灌 ITCM → `CTRL=0x1`（清 HALT）→ 读结果」，
**它连第三步都没走到**。

## 2. 已排除的（都是量过的）

| 假设 | 怎么排除的 |
|---|---|
| **板子坏 / JTAG 被占** | ❌ 已排除：`check_jtag_owner.ps1` 通过、零 DAP 错误、`CYC_TOTAL` 在涨 |
| **PL 或固件有问题** | ❌ 已排除：**同样灌 ITCM + 放核，走纯 JTAG 完全正常** —— `RETIRE_CNT` 1 秒涨 **40,825,093** ≈ 1 指令/周期、`TRAP_CNT=0`、`LED_STATE=0x2`（见 `scripts/probe_core_by_jtag.tcl`）|
| **PS↔PL 的 AXI 从端会挂死** | ❌ 已排除：读通路是固定 3 拍（`ar_fire→rd_issue→rd_wait→rd_pending`）、写通路固定 1 拍（`reg_wr_o→wr_done`），结构上不可能挂；且未译码地址有 `SLVERR` 应答 |
| **`rst -processor` 缺 `-clear-registers`** | ❌ 已排除：加上该选项（XSCT 也确实警告过这点）**现象不变** |
| **ELF 没下载** | ❌ 已排除：`dow` 无报错 |
| **不是"尽早停"就能抓到** | ❌ 试过 `con` 后只等 **10 ms** 就 `stop` —— **照样停不住**。所以卡死发生得**极早**（或 `con` 之前就已经不可 halt）|

## 3. 现在最可能的解释（**推断，未证实**）

**A9 卡在一条永不完成的总线访问上。** 调试 `halt` 需要核到达一个指令边界；
如果核正在等一次不会返回的 load/store，`halt` 就会超时 —— 与观测完全吻合。

**但这一条还没量到**，"访问谁"也没定。候选：PL 的 AXI 窗口（0x43C0_0000）、
DDR、或 `ps7_init` 之后某个还没配好的区域。

## 4. 下一步该怎么做（**别从"再改脚本"开始**）

1. **先跑 `scripts/check_jtag_owner.ps1`** —— 被别的项目抢时，症状可能伪装成本条。见 065。
2. **不要靠延时去抓**（10 ms 都抓不到）。改用**在 ELF 入口下断点**，或走
   **JTAG 启动模式**（让 A9 停在 BootROM，再 `dow` 并把 PC 设到入口），逐个函数走，
   看它卡在哪一条 load/store 上。`scripts/probe_a9_early.tcl` 是那个"靠延时"版本的起点，
   可以改造成断点版。
3. 顺带确认：`ps7_init` 之后**DDR 控制器**是否真的起来了 —— `dow` 把 ELF 写进 DDR，
   如果 DDR 没配好，`dow` 表面成功、A9 一去取指就挂。

## 5. 复现指纹

- **`Cannot halt processor core, timeout` + `mrd` 报 `Execution context is running`
  + UART 全空 + `CTRL` 停在 0x02** ⇒ 就是本条。**先跑 065 的占用检查**，再往下查。
- **`CTRL` 停在软复位默认值** ⇒ app 连"放核"都没走到，**别去 PL 侧找原因** ——
  PL 那边同样的操作走 JTAG 是好的。

---

## 6. 根因与结局（2026-10-04 补，见 [067](067-ddr-part-mismatch-4gb-vs-2gb.md)）

§4 第 3 条那句「顺带确认 `ps7_init` 之后 DDR 控制器是否真的起来了」——**猜对了**，
只是方向还要再往下一层：

**不是"DDR 没起来"，是"DDR 起来了但写不可靠"。**
核心板的 DDR3 是 **NT5CC256M16（4Gb）**，而 `ps7_config.tcl` 里配的是
**MT41K128M16（2Gb）** —— 行地址位数和整套时序都不一样，实测 **写 128 个字丢约 9%**。

于是 §3 的推断（"A9 卡在一条永不完成的总线访问上"）也对，只是那条访问之所以会发生，
是因为**指令本身已经是坏的**：`dow` 把 ELF 写进 DDR 时就丢了约 9% 的字，
A9 取到坏指令 → 执行到野生地址 → 互连挂住 → `halt` 超时。

修法（**已实测通过**）：app 重链到 OCM（`sw/lscript_ocm.ld` + `scripts/build_a9_ocm.sh`），
`run_board.tcl` 优先用它。串口实测 `===== PASS (0 failures) =====`。

⚠ **`ps7_init` 的 DDR PHY 校准通过、日志里没有 `Mask poll failed`，都不能当作 DDR 正常的证据** ——
PHY 只保证"锁得上"，不保证"写得进"。这一条差点让我把 DDR 从怀疑名单里划掉。
