/* FFT 内核的对外接口。实现与定标说明在 fw_fft.c 头部。 */
#ifndef FW_FFT_H
#define FW_FFT_H

#include <stdint.h>

#include "fw_tables.h"          /* g_tw_re / g_tw_im：Q14 旋转因子表（定义在 fw_tables.c）*/

#define FFT_N       1024
#define FFT_NBIN    (FFT_N / 2 + 1)    /* 513 条复数输出 */

/* ── 加速开关（整机对照的**唯一**分叉点）──────────────────────────────
 *
 *   FW_ACCEL = 1（默认）：正/逆变换走核内硬件单元（VFFT / VFFT-inv）
 *   FW_ACCEL = 0        ：全标量基线，**一条自定义指令都不发**
 *
 * 两条路径**逐位等价**（硬件就是照标量那份写的，golden 只有一份），
 * 所以对照实验里改的只有「谁在算」，输入、定标、结果全都不动。
 *
 * ⚠ 基线镜像里 `vfft_count` 会是 0 —— 声学验收门（scripts/acoustic_ps_sim.cpp）
 *   要求 VFFT 真跑过，所以**验收只跑 FW_ACCEL=1 那份**。基线镜像是给
 *   「整机加速比」对照用的，另有它自己的一对 TB（见 tb_fw_chain.v）。
 */
#include "fw_plat.h"            /* FW_ACCEL / FW_HAVE_HW —— 判据在那边 */

/* 位反转表，调 fft1024 前必须调一次。不计入内核计时。 */
void fft_init(void);

/* 1024 点实数 FFT。x 为 1024 个 Q15 样点；out 收 513 条复数 Q15，
 * re/im 交替存放，标度 = 真值 / 1024。
 *
 * out 通常就传固定输出区（FW_OUT_BASE = DTCM 0x2400，见 sw/fw/link.ld）——
 * 内核直写那里，不占 .bss。 */
void fft1024(const int16_t *x, volatile int16_t *out);

/* 实数逆变换（GCC-PHAT 用）：Hermitian 频谱 513 条（re/im 交替）→ 1024 点实序列。
 * 与 fft1024 共用工作区，所以**不能嵌套调用**。 */
void ifft512_real(const int16_t *psi, volatile int16_t *r_out);

#if FW_HAVE_HW
/* 硬件 VFFT 通路（核内 FFT 单元，一条指令跑完整台）。与 fft1024 逐位等价。 */
void fft1024_hw(const int16_t *x, volatile int16_t *out);

/* 硬件逆变换通路（VFFT-inv，指令的 instr[30] = 1）。与 ifft512_real 逐位等价。 */
void ifft512_real_hw(const int16_t *psi, volatile int16_t *r_out);
/* Writes only r[0..15] and r[1008..1023]; requires VFFT SEEK hardware. */
void ifft512_real_ring_hw(const int16_t *psi, volatile int16_t *r_out);
#endif

/* ── 生产路径的两个入口：按 FW_HAVE_HW 选一条 ────────────────────────
 * 用宏不用函数：两条路径**都要**能编进来做对照的是 main 那几处基准段，
 * 生产路径只需要一条，包一层函数调用会白花 .text（见 measurements §6）。 */
#if FW_HAVE_HW
#define fft1024_run(x, out)      fft1024_hw((const int16_t *)(x), (out))
#define ifft512_real_run(p, r)   ifft512_real_hw((const int16_t *)(p), (r))
#else
#define fft1024_run(x, out)      fft1024((const int16_t *)(x), (out))
#define ifft512_real_run(p, r)   ifft512_real((const int16_t *)(p), (r))
#endif

#endif /* FW_FFT_H */
