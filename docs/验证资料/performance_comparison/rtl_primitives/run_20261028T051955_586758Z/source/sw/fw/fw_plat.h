/* 平台开关 —— 「这台机器上到底有没有那几条自定义指令」的**唯一**出处。
 *
 * 为什么单独一个头文件
 * --------------------
 * 这个判据同时被三个地方用：fw_fft.c（VFFT / VFFT-inv）、fw_gsc.c（阵列的
 * PUSH/VRED/VUPD）、fw_main.c（那几段 A/B 基准）。@ 写成三份的话，
 * 最典型的坏法是**只改了两处** —— 于是基线镜像里剩一条真指令，
 * 而"基线"这个前提没有任何东西在守。
 *
 * 两个**互相独立**的条件，别合成一个：
 *   FW_ACCEL          人为地关掉加速，做整机对照（scripts/test_whole_machine.sh）
 *   !defined(__riscv) 这台机器上没有那条指令，`.insn` 根本汇编不过
 *                      （host 侧的定点模型、Cortex-A9 的 PS-only 基线）
 * 合成一个的后果：host/A9 上要么编不过，要么"对照实验"其实什么都没关掉。
 */
#ifndef FW_PLAT_H
#define FW_PLAT_H

#ifndef FW_ACCEL
#define FW_ACCEL 1
#endif

#if FW_ACCEL && defined(__riscv)
#define FW_HAVE_HW 1
#else
#define FW_HAVE_HW 0
#endif

/* ── 工作负载口径（整机对照用）────────────────────────────────────────────
 *
 *   FW_BENCH_ROUND = 1（默认）：**基准轮**。每个内核单独量一次，并且把
 *       "同一件事的另一种做法"也跑一遍留作对照指纹（例：GSC 先标量跑一趟、
 *       再阵列跑一趟，好让两次的 SNR 与指纹可比）。
 *   FW_BENCH_ROUND = 0：**产品形态轮**。去掉那些只为对照而存在的重复段 ——
 *       产品上同一件事只做一次。
 *
 * ⚠ 这不是"哪个更准"的问题，是**两个问题**：
 *     基准轮   = 「把加速器拿掉，这一版固件会慢多少」← 含对照开销
 *     产品形态 = 「产品上这套 PL 值多少」          ← 不含
 *   加速轮里产品形态的那一趟占 48%，基准轮那个对照趟占 52% —— 报数时必须
 *   写明是哪一种。见 docs/measurements.md §13。
 */
#ifndef FW_BENCH_ROUND
#define FW_BENCH_ROUND 1
#endif

/* ── 逐帧抖动（README §35 的"单帧延迟" + §36 的 J = T_max − T_min）────────
 *
 *   FW_JITTER_N = 0（默认）：**这一段整个不编**，现有那一轮一个字都不变。
 *   FW_JITTER_N = n > 0   ：把"一帧的链"连跑 n 次，每次量拍数，记 min/max/sum。
 *
 * ⚠ 两个平台用**不同的 n**，不是偷懒：核上跑一拍要仿一拍（n 大了仿真要几十分钟），
 *   而**核是确定性的** —— n=8 出现 min==max 就已经是结论；
 *   A9 那边要 P95/P99，n 得够大（几百），但它在真板上跑，0.5 秒的事。
 *   两边的**帧内容**必须一模一样，否则比的不是同一件事。
 */
#ifndef FW_JITTER_N
#define FW_JITTER_N 0
#endif

#endif /* FW_PLAT_H */
