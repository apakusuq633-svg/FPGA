# 074 本机的 `ps7_init.tcl` 比 [067](067-ddr-part-mismatch-4gb-vs-2gb.md) 的修复还旧 ⇒ 换过的 BD 白换

**日期**：2026-10-05
**状态**：**已修**（2026-10-05：替换 + **断电重上电**后实测全通过 ——
DDR 写 **11/128 → 0/128**；RV32 核 1 s 内退役 **40,983,285** 条指令、`TRAP_CNT` 全 0
（修前 `RETIRE_CNT` 恒 0）；app `failures` **垃圾值 → `0`**（A9 `pc`=`0x100680`、`CPSR` 模式 `0x1F`）；
W0 系数 bank 经独立口回读 **0/120** 非零。数字全部在 `docs/measurements.md` §1）。
**相关**：[067](067-ddr-part-mismatch-4gb-vs-2gb.md)（同一条链的**上半段**：参数本身配错）、
[066](066-a9-app-never-releases-core.md)（症状那一面）、
[064](064-run-board-apu-chicken-and-egg.md)（DAP 恢复的绕法）、`scripts/ps7_config.tcl`

---

## 1. 症状

和 [067](067-ddr-part-mismatch-4gb-vs-2gb.md) 一模一样，所以一开始被当成"067 又犯了"：

```
dow $elf      → pc = 0x100000        ✅ 入口对
con; after 2000; stop
              → AP transaction timeout   ✗ DAP 挂死
（更早一次）   pc = 0x8，CPSR 模式 13（SVC）
              CTRL = 0x2 / STATUS = 0x4   ← 都是复位值，说明 PL 侧核从没被启动
              failures @0x108024 = 0x29C30DD7  ← 垃圾，.bss 从未清零
```

`failures` 是垃圾值这一条最关键：它说明 **C 运行时根本没跑到清 `.bss`**。
而 `_start` 早期就要设栈，栈在 DDR ⇒ 一 push 就碰 DDR。

## 2. 误判

- **先怀疑板子身份对不上**。`run_board.tcl` 第 1 行写的是 "Navigator Zynq-7010"，
  而工程 part 是 `xc7z020clg400-1`；如果板子真是 7010，DDR 型号、位宽全不对，
  这条能独立解释全部现象。→ 跑 `scripts/detect_board.tcl`（只读，不复位），
  实测 JTAG 上就是 **`xc7z020`**，与工程一致，**排除**。
- **怀疑 `anc_app` 缺了**。它是 `install_ps_app.ps1` manifest 里有、但
  `create_ps_apps.tcl` / `run_board.tcl` 白名单里没有的孤儿，看着像"少建了一个 app"。
  与本次无关，但顺手确认了它确实 0 引用。
- 真正**差点没查**的一步：以为 067 写着"已修（2026-10-04）"，本机就该是修好的。

## 3. 根因

**DDR 的配置不进 bitstream。** PS7 的 DDR 控制器参数只在 `ps7_init.tcl` 里，
运行时由 JTAG / FSBL 写进 PS 寄存器。所以"BD 重建过 + bitstream 重编过" **完全不能说明**
上板时用的 DDR 参数是对的。

[067](067-ddr-part-mismatch-4gb-vs-2gb.md) 的修复分两步：① 改 `scripts/ps7_config.tcl`
（BD 源）；② **换掉 `ps7_init.tcl`**。本机第 ① 步在源码里（`CONFIG.PCW_DDR_RAM_HIGHADDR {0x3FFFFFFF}`、
`CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125}`，第 87 / 353 行），本次 Vivado
也确实按它重建 BD 并生成了新的 `ps7_init.tcl`（Oct 5 15:22）。

**但第 ② 步在本机从没做过**：上板脚本加载的是 `D:\Vitis\PS-PL\hw\ps7_init.tcl`，
时间戳 **Sep 21 22:11**，比 10-04 的修复还早 —— 说明 10-04 那次替换发生在**另一台机器**
（和 `D:\Vivado` vs 本机 `E:\Vivado2020.2` 同源的环境差异）。

⇒ 新 bitstream 配着**旧 DDR 参数**跑，A9 一碰 DDR 就取到坏数据，跑到野生地址，
PS 互连连同 DAP 一起挂住。067 第 1 节描述的正是这个形态。

## 4. 修法

新 `ps7_init.tcl` 的**正确来源**是 BD 的 `generate_target` 产出物（067 已记：对 PS7 IP 跑什么都不出，
必须对 **BD** 跑）：

```
vivado_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl   (Oct 5 15:22)
```

替换两处（旧版留 `.bak-sep21`）：

```bash
cp -p /d/Vitis/PS-PL/hw/ps7_init.tcl                 /d/Vitis/PS-PL/hw/ps7_init.tcl.bak-sep21
cp -p /d/Vitis/PS-PL/export/PS-PL/hw/ps7_init.tcl    /d/Vitis/PS-PL/export/PS-PL/hw/ps7_init.tcl.bak-sep21
cp <BD 产出>/ps7_init.tcl /d/Vitis/PS-PL/hw/ps7_init.tcl
cp <BD 产出>/ps7_init.tcl /d/Vitis/PS-PL/export/PS-PL/hw/ps7_init.tcl
```

替换后两处 md5 = `69aec0e1e60ca949d53df31b09310692`，26573 B（旧版 28925 B）。

⚠ `D:\Vitis\<app>\_ide\psinit\ps7_init.tcl` 那一批是各 app 的调试副本，同样是 Sep 21 的旧版，
本次没动（上板链路走的是 `PS-PL/hw/` 那份）；等 067 那条链整体复查时一并处理。

## 5. 复现指纹

**判据**：把两份 `ps7_init.tcl` 拉出来 diff。旧版**多 14 行** `0xF8000740..0xF80007D4`
（DDR PHY 的 IO delay / DQS 校准寄存器），且 DDR 段三个 proc
（`ps7_ddr_init_data_3_0` / `_2_0` / `_1_0`）各差一组值：

| 寄存器 | 旧（2Gb / MT41K128M16） | 新（4Gb / MT41K256M16） |
|---|---|---|
| `0xF8006014` | `0x0004159B` | `0x0004285B` |
| `0xF8006044` | `0x0FF66666` | `0x0F666666` |
| `0xF800012C` | `0x015C004D` | `0x015C000D` |
| `0xF8000154` | `0x00000A01` | `0x00001001` |
| `0xF8000168` | `0x00000501` | `0x00000801` |
| `0xF8000170` | `0x00500500` | `0x00500800` |

```bash
diff /d/Vitis/PS-PL/hw/ps7_init.tcl.bak-sep21 <BD 产出>/ps7_init.tcl   # 129 行
grep -n "0XF8006014" /d/Vitis/PS-PL/hw/ps7_init.tcl                     # 应为 0x0004285B
ls -la /d/Vitis/PS-PL/hw/ps7_init.tcl                                   # 不应还是 Sep 21
```

**另一条指纹（DAP 挂死后怎么恢复）**：`rst -system` **救不回来**，实测报
`Cannot reset DAP. AP transaction error, DAP status 0x30000021`
（`scripts/probe_ps_recover.tcl` 走完 `PS_RECOVER_FAIL`）⇒ **只能物理断电重上电**。
067 第 1 节也记过"断电才能恢复"——**别在这上面反复试脚本**。
