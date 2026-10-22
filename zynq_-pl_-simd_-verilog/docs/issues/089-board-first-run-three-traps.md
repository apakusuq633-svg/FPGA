# 089 第一次上板跑 PS-only：三个"看起来完全合理"的坑

**状态**：两个已修；`lscript_ocm.ld` 那个 **待修**（DDR 路线是规范路线，不影响交付）
**日期**：2026-10-08
**阶段**：README §34 的 PS-only 那一半上板取值
**复现**：`xsct build/board_run.tcl build/ps_only_arm/ps_only_ddr.elf ps_only`

---

## ① PMCR 的 ÷64：读到的数**小 64 倍，而它看起来完全合理**

**症状**：PS-only 整轮读出 **156,550** A9 拍。串口打出
`PS_ONLY_RES … C0DE0001`，所有指纹与 PL 侧逐位一致 —— **计算是对的**。

**误判**：差点直接采信。156,550 拍 @667 MHz = 0.23 ms，比 PL 的 16.75 M 拍
（40 MHz = 419 ms）"快 1800 倍"—— 一个让人**只会感叹"PS 果然快"**、
不会去怀疑计数器的数。

**根因**：Cortex-A9 的 `PMCR`（`mrc p15,0,rx,c9,c12,0`）**bit[3] = D 复位默认是 1**
⇒ **PMCCNTR 每 64 个 CPU 时钟才加一**。我只置了 bit0(E) 和 bit2(C)，
没有清 bit3。

**修法**：`v &= ~(1u << 3);`，并把 PMCR 回读打进串口
（`PS_ONLY_PMCR 41093001`，D=0 / E=1 都要能一眼看见）。

**验证**：清掉之后 **9,944,153** 拍 —— 与 156,550 × 64 = 10,019,200 的比值是
**63.5**，对上了（差的 0.8% 是那次多打了一行 PMCR）。

**指纹**：**"快得不符合物理"就是计数器坏了，不是 CPU 强。**
拿"同一份工作在两台机器上的拍数之比"做量级自检 —— 这里 1675 万 vs 15.6 万
是 107 倍，而 A9 对 RV32 的双发射优势最多 2 倍 ⇒ 立刻可疑。
与 [057](057-first-real-timing-measurement.md) 同族：**第一个数字往往不是答案。**

## ② OCM 只到 0x2FFFF，`sw/lscript_ocm.ld` 却声明到 0x3FFFF

**症状 A（第一次跑 ps_only）**：串口**一个字节都没有**。JTAG 探针说 A9 在
**Abort 模式**（CPSR `0x200001d7` → mode 23），PC 跑到 0x22850，
结果块全 0 —— 连 main 最开始那 16 个探针字都没写进去。
反汇编定位到 abort 发生在 `DataAbortHandler` 自己的 `str r1,[r0]` 上
（LR_abt = 0x200F8 = 该指令 + 8），而 `r0 = *(0x20124) = 0x2FFC0`。

**症状 B（改跑声学 app）**：`dow` 直接报
`Memory write error at 0x30000. **OCM is not enabled at 0x00030000**`。

**误判**：先怀疑 `.data` 的 LMA(0x13c98) ≠ VMA(0x23c98) 导致 `dow` 装错 ——
**读回 `fw_mem_scratch` = 0x2DFC0，正确**，假设推翻。

**根因**：`sw/lscript_ocm.ld` 的 `MEMORY` 写的是
`ps7_ocm_0 : ORIGIN = 0x00020000, LENGTH = 0x00020000`（⇒ 到 0x3FFFF），
而**BSP 自己的 `D:/Vitis/rv32_app/src/lscript.ld` 写的是**
`ps7_ram_0 : ORIGIN = 0x0, LENGTH = 0x30000` —— **OCM 只有 192 KB**。
ps_only 的 `.stack` 落在 0x31FD0，**一用栈就 data abort**；
声学 app 的 `.bss`/`.heap` 更是直接从 0x30008 起。

**修法**：改用 **DDR 链接脚本**（`D:/Vitis/rv32_app/src/lscript.ld`）。
`scripts/run_board.tcl` 的注释本来就写着"**DDR 已于 2026-10-04 修好 ⇒ 以 Vitis 的为准**，
OCM 版只在它缺失时兜底"—— 我一开始选错了脚本。

**待修**：`sw/lscript_ocm.ld` 的 `LENGTH` 该是 `0x00010000`（0x20000..0x2FFFF）。
**不建议现在改**：DDR 是规范路线，而改了之后 73 KB 的声学 app 就装不进 OCM 了
（那其实是**好事** —— 它当场就会报链接错，而不是上板之后静默 abort）。
留这条记录，别让它再咬第二次。

**指纹**：**串口全空 + A9 停在 Abort 模式 + 结果块全 0** ⇒ 先查 `.map` 里
栈和 .bss 落在哪个物理地址、那段地址在**器件上**是否真的可用。
**链接器不会报错**：它只按脚本里的 MEMORY 段算，脚本写大了它就信。

## ③ `run_board.tcl` 在本机跑不了（环境问题伪装成"板子被占"）

**症状**：`scripts/run_board.tcl` 一上来就 `error "JTAG 被别的项目占用，已中止"`，
而当时 JTAG 是空的。

**根因**：它 `source jtag_guard.tcl`，guard 里是
`exec powershell -NoProfile -ExecutionPolicy Bypass -File check_jtag_owner.ps1`。
**本机 PowerShell 执行策略是 Restricted**（跑任何 `.ps1` 都报
"在此系统上禁止运行脚本"）⇒ `exec` 失败 ⇒ `catch` ⇒ guard 无条件判"被占用"。

**修法**：`build/board_run.tcl` —— `run_board.tcl` 的等价物，占用判据**内联**，
判据与 `check_jtag_owner.ps1` 一字不差（看**命令行**里有没有
`multichannel_acoustic`，不是看进程名，因为两边都叫 xsct/hw_server）。

**指纹**：**"被占用"的报错在你明知板子空着的时候出现** ⇒ 先看 guard 自己跑没跑成，
别去查板子。与 [018](018-vivado-bd-flow-environment.md) 同族：
环境问题长得像别的问题。
