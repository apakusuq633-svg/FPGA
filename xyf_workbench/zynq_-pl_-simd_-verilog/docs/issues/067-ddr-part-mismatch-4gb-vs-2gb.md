# 067 DDR 颗粒型号配错（**4Gb 的板配成 2Gb**）⇒ 写丢约 9%，把 A9 整条路径堵死

**日期**：2026-10-04
**状态**：**已修**（2026-10-04：DDR 参数按 7020 厂商例程改正，`probe_write_drop_ocm_vs_ddr`
实测 **DDR 11/128 → 0/128**；**DDR 版 app 端到端 `PASS (0 failures)`**）。
绕过办法（OCM）保留可用，但不再是必需的。
**相关**：[066](066-a9-app-never-releases-core.md)（本条的**症状**那一面）、
[065](065-shared-jtag-two-projects.md) / [064](064-run-board-apu-chicken-and-egg.md)（同码但不同因的两个上板坑）、
`docs/board_io.md`（2026-10-01 就标成"风险最高的一项"）、`scripts/ps7_config.tcl`

---

## 1. 症状

从 [066](066-a9-app-never-releases-core.md) 收窄下来的：

```
A9 一 con 就  stop 报 Cannot halt processor core, timeout
接着        AP transaction timeout
换到 A9#1   也报 DAP status 0xF0000021
```

**整块板子一起锁死，软件救不回来** —— 换新 `hw_server`、`targets 1` + `rst -system`、
`disconnect`/`connect`、JTAG 频率降到 3M/1M/500k/200k，**全部无效**，只能断电重上电。
（判据：`fpga -file` 在 `xc7z020` 上**仍然成功** ⇒ 线缆与 PL TAP 完好，坏的只有 PS 侧 DAP。）

## 2. 误判（**这份档案最值钱的部分**）

| # | 当时的判断 | 怎么被推翻的 |
|---|---|---|
| ① | 「跑 A9 app 会把 DAP 弄坏」→ 板子/位流坏了 | [065](065-shared-jtag-two-projects.md)：是**另一个项目在同一块板子上抢 JTAG**。时间上的巧合当成了因果 |
| ② | **「DDR 存不住数据 / 刷新没跑」** | 保持性实验：写进去的值 **10 秒后还在** ⇒ 刷新正常，**衰减排除** |
| ③ | **「`dow` 下去的内容 71% 是坏的」** | 两件事叠加：**(a)** 我的**比对代码有大小写 bug** —— 一侧 `$g` 小写、另一侧 `[fmt32]` 大写，**凡值里含 A–F 的全被判成"不符"**，而且打印出来 `want` 和 `got` 一模一样（见下）；**(b)** 同一块内存连读三遍三遍互不相同 ⇒ 读数本身也不可信 |
| ③b | 同上这个 bug **又犯了一次**（在 `probe_ddr_app_intact.tcl` 里），修完 DDR 后仍报 5722/8194 | **这次是靠"盯打印结果"发现的** —— 输出的每一行 `want` 和 `got` 明明相等却被计数。**桩测试抓不到它**（桩没有大小写语义）。⇒ 探针脚本打印出来的样本行必须能自证 |
| ④ | **「DAP/JTAG 主机通路在丢写」** | 对照实验：**同一套 `mwr` 循环**写 **OCM（片上 SRAM）0 错**，写 DDR 11/128 错 ⇒ 不是主机通路 |
| ⑤ | 「MMU 页表映射错了」 | 把 `.mmu_tbl` 整张倒出来：完整 16 KB、在单个 LOAD 段内，PL 区 `0x43C00C02`、UART/SLCR/SCU 是 device、未用区是 FAULT —— 映射没问题 |
| ⑥ | 「L2 cache（PL310）没初始化」 | 反汇编 boot.S：aux/tag-lat/data-lat/SLCR L2C RAM 一整套都在，初始化完整 |

**两次栽在"测法本身没做对照"上**（②③④）。特别是 ③：`dow` 之后逐字比对做得很认真，
却没有先花一步问「我这个**读**回来的手段自己稳不稳」。
**读数不稳时，比对做得再仔细也只是在放大噪声。**

## 3. 根因

**核心板的 DDR3 颗粒型号与 `ps7_config.tcl` 里配的不是同一颗。**

| | 板上实际 | 配置里写的 |
|---|---|---|
| 型号 | **NT5CC256M16**（Nanya） | `MT41K128M16 JT-125`（Micron） |
| 容量/颗 | 256M×16 = **4Gb = 512 MB** | 128M×16 = 2Gb = 256 MB |
| 两颗 32 位合计 | **1 GB** | 512 MB |
| 行地址位 | **15（A0–A14）** | 14（A0–A13） |

- 板上实际：原理图第 8 页（`ZYNQ7010_7020核心板原理图_2V5.pdf`，用 `pdftotext` 抽出
  `NT5CC256M16`，两颗）；整页块图写的是 `DDR3 SDRAM(4Gb/2Gb)`。
- 配置侧：`PCW_UIPARAM_DDR_PARTNO` / `PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF}`。

行地址少一根 + tRCD/tRP/tRFC/tRAS 整套按 2Gb 算 ⇒ **写时序余量不够**。

**实测**（`scripts/probe_write_drop_ocm_vs_ddr.tcl`，A9 停止，全程不执行 A9 代码）：

```
OCM 直接写 128 字   不符  0 / 128
DDR 直接写 128 字   不符 11 / 128      <-- 约 9%
```

坏法有指向性：

```
want a5a50022   got 40000022     ← 低 16 位对，高 16 位还是**上一轮的旧值**
want a5a5002b   got 4000002b
want a5a50031   got 40000031
```

**只有低 16 位落盘，高 16 位没写进去** —— 32 位总线上的高半颗颗粒（或它的字节通道）时序不够。

链条闭合：`dow` 把 ELF 写进 DDR 0x100000 时就丢了约 9% 的字 → A9 取到坏指令 →
执行到野生地址 → PS 互连被一个永不完成的访问挂住 → **连 DAP 一起超时** → 只能断电。

⚠ **最误导人的一点**：`ps7_init` 的 DDR PHY 校准**照样通过** —— 把 `build/` 下所有日志
grep `Mask poll` / `Timeout Reached`，**零命中**。PHY 校准只问"能不能锁上"，
不问"时序余量够不够"。
**⇒ 「ps7_init 没报错」不能当作「DDR 正常」的证据。**

这条其实在换板当天就被标出来了 —— `board_io.md` 2026-10-01：
「**最大风险项是 DDR**：`ps7_config.tcl` 是从 **7010 的**厂商例程导出的……
在这件事做完之前，这是整个换板动作里风险最高的一项。」**三天里一直没做。**

## 4. 修法

### 4.1 绕过（**已做，实测通过**）

app 改从 **OCM** 跑，完全不碰 DDR。OCM 是片上 SRAM，实测写 128 字 **0 错**。
app 只要 48 KB，OCM 可用 128 KB（低 128 KB 被 BootROM 占着），放得下。

| 文件 | 作用 |
|---|---|
| `sw/lscript_ocm.ld` | 由 `lscript.ld` 改一个 MEMORY 区：`ps7_ocm_0 : ORIGIN = 0x00020000, LENGTH = 0x00020000` |
| `scripts/build_a9_ocm.sh` | 构建 `build/a9_ocm/rv32_app_ocm.elf`。**不用 Vitis 的 makefile**（它把链接脚本写死成 `../src/lscript.ld`，而 `D:\Vitis` 是两个项目**共用**的），直接调 `arm-none-eabi-gcc` 只换 `-T`；源码仍取 `sw/ps_main.c`（版本库唯一真源） |
| `scripts/run_board.tcl` | 加了 `-elf <path>` 覆盖参数（复验 DDR 版就是靠它）；Vitis 的 DDR 版缺失时才回退到 OCM 版。<br>**DDR 修好后已恢复"以 Vitis 的为准"** —— OCM 路线保留但不再是默认 |
| `scripts/probe_a9_run_from_ocm.tcl` | 上板验证探针（断点在 main，确认 boot.S 走过去了再放它自由跑） |

**实测**（串口 115200，`build/a9_uart_ocm.log`）：

```
===== RV32 PS-PL interface test =====
base address 0x43c00000
[1] soft reset            [ok] core is HALTed after soft reset
                          [ok] soft reset cleared the LEDs to 0
[2] downloading firmware into ITCM (15 words)
                          [ok] write + readback check passed
                          [ok] DTCM write + readback passed (bank select works)
                          [ok] nothing rejected during download
[3] released, core starts running
[4] sampling 6 rounds     RETIRE_CNT: 531176 -> 95768999，TRAP_CNT 恒 0
[5] results               [ok] x4
===== PASS (0 failures) =====
```

**本工程历史上第一次跑通 A9 路径**，也是串口第一次收到 PS 的输出。
PL 侧寄存器同时印证：`CTRL=0`（HALT 已清）、`STATUS=0x0B`、`RETIRE_CNT=0x06ECE458`、`TOHOST_CNT=3`。

### 4.2 真修（**已完成，2026-10-04**）

**7020 的厂商例程拿到了**：`D:\BaiduNetdiskDownload\ZYNQ_Vitis_7020\ZYNQ_Vitis_7020`
（44 个例程）。★ 注意要的是 **`4_Source_Code/2_Embedded_Vitis` 那一支**；
`ZYNQ_7020_FPGA` 那个文件夹是**纯 PL 例程**（48 个 `.xpr`、**0 个 `.bd`**、
RTL 里没有 `processing_system7`），取不到 PS7 配置。

**选源工程**：在 44 个例程里扫了一遍，`20_pl_rw_ddr` 与现有配置差异最小（13 条）。

**差异只有两条**（其余 75 条 DDR 参数、以及全部 DQS 长度/board delay **一字不差**
⇒ 7010 与 7020 核心板是同一块 PCB，只换了颗粒）：

```
PCW_DDR_RAM_HIGHADDR   0x1FFFFFFF -> 0x3FFFFFFF     512 MB -> 1 GB
PCW_UIPARAM_DDR_PARTNO MT41K128M16 JT-125 -> MT41K256M16 RE-125   2Gb -> 4Gb
```

⚠ **只改了这两条，其余 322 条保持 7010 例程原值，是刻意的**：那个 7020 例程
除 DDR 外还有 13 条差异（FCLK0 频率、CLK0/RST0 端口、`USE_S_AXI_HP0`、
`CPU_6X4X_MAX_RANGE` 667→767）。其中 FCLK0/CLK0/RST0/M_AXI_GP0/IRQ_F2P 那几条
`create_zynq_project.tcl` 本来就会覆盖，**但 `USE_S_AXI_HP0` 和 `CPU_6X4X_MAX_RANGE`
不覆盖** —— 整份采用会引入两条与本问题无关的变量，出问题时无法归因。
（这是对 `ps7_config.tcl` 头部「勿手改」的一次**有意偏离**，偏离理由已写在该文件头部。）

**改完之后的流程**（踩到两个坑，记下来）：

1. `vivado -mode batch -source scripts/create_zynq_project.tcl` 重建 BD。
   ⚠ 它用 `create_project -force`，**会把 `vivado_zynq/` 连同已实现的位流一起删掉** ——
   跑之前先把 `*.bit` 备份出去。
2. **`ps7_init.tcl` 不在 PS7 IP 自己的 output products 里**：
   `get_property SUPPORTED_TARGETS [get_ips ps_pl_u_ps7_0]` 只有
   `instantiation_template synthesis simulation misc changelog`，**没有 handoff**。
   必须对 **BD** 跑 `generate_target all [get_files ps_pl.bd]` 才会产出
   `vivado_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl`。
3. 新的 `ps7_init` 与旧的**只差 2 条寄存器写**（3 个硅版本各一份，内容一致）：
   ```
   0xF8006014  0x0004159B -> 0x0004285B
   0xF8006044  0x0FF66666 -> 0F666666
   ```
   拷到 `D:/Vitis/PS-PL/hw/ps7_init.tcl`（连同 `ps7_init.c`）。
4. **PL 网表没变 ⇒ 位流不用重做**（Zynq 的 PS 配置是软件在启动时写进 SLCR/DDRC 的，
   不进位流）。所以先用备份的旧位流就地把修复验掉，之后再跑完整流程让工程自洽。

**实测判据**：

| 测量 | 修前 | 修后 |
|---|---|---|
| `probe_write_drop_ocm_vs_ddr`：DDR 直接写 128 字 | **11 / 128 错** | **0 / 128** ✓ |
| 同脚本：OCM（对照） | 0 / 128 | 0 / 128 |
| `run_board.tcl -app rv32_app -elf <Vitis 的 DDR 版 ELF>` | 卡死、要断电 | **`PASS (0 failures)`** ✓ |

串口实测（`build/a9_ddr_after_fix.log`）：DDR 版 app 走完 [1]→[5] 全绿，
`RETIRE_CNT` 涨到 9576 万、`TRAP_CNT=0`、`TOHOST_CNT=3`。
**⇒ 根因真正修好，不是绕过。**

## 5. 复现 / 指纹

- **`Cannot halt processor core, timeout`，紧接着连别的核都报 DAP 错误，且断电才能恢复**
  ⇒ 怀疑 **CPU 访问了一个永不完成的地址**。先按 [065](065-shared-jtag-two-projects.md) /
  [064](064-run-board-apu-chicken-and-egg.md) 排掉"别人在抢"和"复位序列"，再回到本条。
- **一条命令区分「DDR 坏」和「DAP/JTAG 通路坏」**（`scripts/probe_write_drop_ocm_vs_ddr.tcl`）：
  同一套 `mwr` 循环分别写 OCM（0x00020000）和 DDR，逐字回读。
  - OCM 0 错、DDR 有错 ⇒ **DDR 的锅**，别去动 hw_server / JTAG 频率
  - 两边都错 ⇒ 主机通路（降 JTAG 频率 / 换 USB 口 / 重启 hw_server）
- **坏法指纹**：高 16 位写不进去、低 16 位对 ⇒ 32 位总线的高半颗颗粒时序不够
  ⇒ 直接去核 DDR 颗粒型号 vs `PCW_UIPARAM_DDR_PARTNO`。
  板上型号从原理图抽：`pdftotext -layout <原理图.pdf> - | grep -oE "NT5C[A-Z0-9]+|MT41[A-Z0-9]+"`
- ⚠ **测之前先给自己的测法做对照**：同一块内存**连读三遍**。
  三遍不一致 ⇒ 读数不可信，此时任何"比对不符"的结论都要作废（本次栽过一次）。
- ⚠ **比对代码两侧都要归一化再比**（大小写 / 有无 `0x` 前缀 / 前导零）。
  本次同一个 bug 犯了两次，第二次表现是"打印出来的 want 和 got 一模一样却被计数"。
  ⇒ **探针输出的样本行必须能自证**：随便挑一行看，`want` 和 `got` 不等才是真不符。
- ⚠ **`ps7_init` 校准通过 ≠ DDR 正常**。PHY 只保证"锁得上"，不保证"写得进"。
- **改动 DDR/PS7 配置后的完整动作**（少一步就白跑）：
  `ps7_config.tcl` → `create_zynq_project.tcl`（★ 先备份 `*.bit`，它 `-force` 会删）
  → **对 BD 跑 `generate_target all`**（不是对 PS7 IP，它的 SUPPORTED_TARGETS 里没有 handoff）
  → 拷 `ps7_init.tcl`/`.c` 到 `D:/Vitis/PS-PL/hw/`
  → `probe_write_drop_ocm_vs_ddr.tcl` 判 DDR 是否 0 错 → 再跑 app。
