/* 启动代码：设栈 → 清 .bss → 进 main。
 *
 * 复位向量在 0x0000（rv32_soc 的 RESET_PC 默认值），所以这一段必须排在最前，
 * 由链接脚本的 *(.text.start) 保证。
 *
 * **没有 .data 搬运** —— 不是省了，是搬不了：.data 的初值在 DTCM 镜像里，
 * 由加载方（仿真走 DTCM_FILE，上板走 PS 的 MEM_SEL_DTCM 窗口）直接预装。
 * 旧版这里有一句「从 ITCM 的 LMA 拷到 DTCM」的循环，它读的是数据端口，
 * 而数据端口只打到 DTCM —— 读回来的是同地址的 DTCM 内容，拷过去全是垃圾。
 * 详见 sw/fw/link.ld 头部与 docs/issues/031。
 *
 * 不做的事：不初始化任何外设、不开中断。外设由 main 自己按需配置 ——
 * 启动段越短，出问题时越容易二分。
 */
  .section .text.start, "ax", @progbits
  .globl _start
  .type  _start, @function
_start:
  /* 栈设在 DTCM 顶端 */
  la    sp, _stack_top

  /* 清 .bss。.bss 不在镜像里，必须由核自己清。 */
  la    t0, _bss_start
  la    t1, _bss_end
1:
  bgeu  t0, t1, 2f
  sw    zero, 0(t0)
  addi  t0, t0, 4
  j     1b
2:

  call  main

  /* main 返回后停在这里。上板时这里是「跑完了」的可见证据，
     仿真里 TB 也靠 PC 停在这一带来判定结束。 */
5:
  j     5b

  .size _start, . - _start
