/* RV32 固件链接脚本 —— PL 侧定位链的全部内核跑在这上面。
 *
 * 内存映射（见 rtl/soc/rv32_soc.v）：
 *   ITCM  0x0000–0x3FFF  16 KB  取指（dmem 访问**不会**落到这里）
 *   DTCM  0x0000–0x3FFF  16 KB  数据（imem 取指**不会**落到这里）
 *   MMIO  0x4000 邮箱 / 0x5000 GPIO / 0x8000 SRP / 0x9000 XSPEC / 0xA000 转向
 *
 * ⚠ ITCM 与 DTCM 的地址空间**故意重叠**：它们是两块独立的存储器，由
 *   「取指端口 vs 数据端口」区分，不是由地址区分。
 *
 * ── 为什么 .rodata 也放在 DTCM（0x0000 起），不留在代码段 ──────────────────
 * 核的访存端口只按地址译码，**全部**打到 DTCM。所以放在 0x0000–0x1FFF 的
 * .rodata 用 `lw` 读到的是 DTCM 同地址的内容，不是 ITCM 里的常量。
 * 实测指纹（docs/issues/031）：`static const int16_t t[8]` 求和写回结果是 X，
 * 而反汇编里那几条 `lhu` 完全正常。
 *
 * 所以只读常量必须落在**数据**镜像里。这就是下面把 `.rodata` 并进 `.data`
 * 那一段的原因 —— 不是为了省事，是唯一能读到的地方。
 *
 * ── 数据镜像是「预装」的，不由启动代码搬运 ─────────────────────────────────
 * 同上：`.data` 的初值如果留在 ITCM 里（旧版把 LMA 排在 .text 之后），
 * 启动代码那句 `lw t3, 0(t0)` 一样读不到，拷过去的是垃圾。所以链接脚本让
 * `.data` 的 LMA **等于** VMA（都在 DTCM 0x0000），由加载方直接写进 DTCM：
 *   仿真   tb 的 DTCM_FILE 参数
 *   上板   PS 侧 MEM_ADDR/MEM_WDATA 窗口的 MEM_SEL_DTCM（sw/ps_main.c 已有）
 * 启动代码里那句 .data 搬运因此删掉了（见 sw/fw/start.S）。
 *
 * 代价：**数据区必须整体写进 DTCM 才能运行**。少写这一份的表现是所有初值
 * 为 0 / X，而代码照跑不误 —— 不报错。
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

/* 两块**独立**的存储器，地址空间故意重叠（见文件头）。
   必须声明成两个 region：只写一个 MEM 的话，.text 与 .data 的 LMA 都是 0，
   ld 会报 "section .data LMA overlaps section .text LMA" 直接失败 ——
   它按地址判重叠，看不见「这是两块不同的 RAM」。 */
MEMORY
{
  ITCM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
  DTCM (rw) : ORIGIN = 0x00000000, LENGTH = 16K
  /* .data 的 LMA 占位区：**不放任何东西**，只是让 ld 的「LMA 不许重叠」这条
     检查通过 —— .text 与 .data 的 VMA 都是 0，LMA 若也取 0 就会被判重叠。
     真正的加载地址是 DTCM 0x0000，由单独导出的 DTCM 镜像负责。 */
  DLMA (rw) : ORIGIN = 0x00010000, LENGTH = 16K
}

SECTIONS
{
  /* 代码段：只放指令。上限由 build_fw.sh 的 TEXT_LIMIT 卡（2026-10-06 起 0x2400）。
     ⚠ 原先这里写的是"必须整体留在 0x2000 以下"，理由是"越过 0x2000 的字会被
       加载方写进 ITCM 的高半区，而数据区在 DTCM 里永远拿不到它们"。**那个理由
       现在不成立了**：ITCM 是 16 KB / 4096 字，高半区本来就是有效存储；两个加载方
       （仿真的 $readmemh、上板的 download_to_tcm）都按**字号**填，没有 0x2000
       这条线。0x2000 是早期设计（.data 的 LMA 排在 .text 之后）留下的守卫，
       而 link.ld 早已改成 DTCM 预装（见下面 .data 那段）。
     ⚠ 但**别把这条当"随便长"**：ITCM 16 KB 仍然是硬的，闸门只是挪到了 0x2400。 */
  .text 0x0000 : {
    *(.text.start)
    *(.text*)
    . = ALIGN(4);
  } > ITCM

  /* 数据段（初值 + 只读常量）：VMA = LMA = DTCM 0x0000，由加载方预装。
     `.sdata` / `.srodata` 必须显式写出来：`*(.data*)` 匹配不到 `.sdata`，
     漏掉它这个段会变成**孤儿段**，ld 把它丢到默认位置且初值全丢 ——
     症状同样是「读常量得到 X」，而 .data 那部分一切正常。 */
  .data 0x0000 : {
    _data_start = .;
    *(.data*)
    *(.sdata*)
    *(.rodata*)
    *(.srodata*)
    . = ALIGN(4);
    _data_end = .;
  } > DTCM AT> DLMA

  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > DTCM

  /* 批量输出区 1：固定在 DTCM 0x2880，2.1 KB（FFT 输出 2052 B）。点数多的内核（FFT/SRP）把整段结果
     写在这里，TB / PS 按绝对地址读。**必须是固定地址** —— 放在 .bss 里的话
     地址随链接结果浮动，TB 拿不到。
     内核**直接写这里**，不再经 .bss 中转：中转要多占一份缓冲区（FFT 是 2 KB），
     而这块存储器本来就是 RAM，直写不多花一拍。
     边界也是在这里生效的：.bss 一旦长过 0x2800（.fwres 的起点），ld 直接报重叠。
     地址与 sw/fw/fw_mem.h 的 FW_OUT_BASE 必须一字不差 —— 漂过一次，见 032。 */
  .fwout 0x2880 (NOLOAD) : { . = . + 0x840; } > DTCM

  /* 结果块：固定在 DTCM 0x2800，TB 与 PS 都按这个绝对地址读。
     显式占位是为了**挡住 .bss 长过来** —— 不写这一段的话，.bss 一旦扩到
     0x2800 就会和固件写的结果互相覆盖，表现为"结果偶尔对偶尔错"。
     ⚠ 它排在 .fwout **前面**：FFT 的输出是 2052 B，从 0x2880 起正好到
     0x3003 —— 若结果块留在 0x3000，最后 4 个字节（bin 512 那条）会被
     结果块盖掉。两个 NOLOAD 段重叠 ld **不报**，实测表现为"513 条里
     只有 bin 512 不对"。 */
  .fwres 0x2800 (NOLOAD) : { . = . + 0x80; } > DTCM

  /* 批量输出区 2：DTCM 0x30C0，2 KB。同 .fwout，但给**第二个**需要留住大块
     结果的内核 —— FFT 与 GCC-PHAT 在同一轮固件里都跑，一份输出区留不住两份。
     地址与 sw/fw/fw_mem.h 的 FW_OUT2_BASE 必须一字不差。 */
  .fwout2 0x30C0 (NOLOAD) : { . = . + 0x800; } > DTCM

  /* FIR and steering result blocks; the intervening gap stays reserved.
     Stack starts above 0x3C80. Keep addresses in sync with fw_mem.h. */
  .fwaudio 0x38C0 (NOLOAD) : { . = . + 0x20; } > DTCM
  .fwsteer 0x3C60 (NOLOAD) : { . = . + 0x20; } > DTCM

  _stack_top = 0x3FF0;           /* DTCM 顶端往下留 16 字节 */

  /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
