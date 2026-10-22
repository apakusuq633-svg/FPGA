/* SRP 空间扫描内核对外接口。实现与内存约束说明在 fw_srp.c 头部。 */
#ifndef FW_SRP_H
#define FW_SRP_H

#include <stdint.h>

/* 固件基线的扫描网格。
 *
 * ⚠ **不是规格里的 32×32**。规格是 32×32 = 1024 点，累加器 P 要 4 KB
 *   （int32 × 1024），而 DTCM 一共只有 16 KB，腾不出这 4 KB 连续空间
 *   （见 fw_srp.c 头部的账）。基线取 16×16 = 256 点，P 只要 1 KB。
 *
 *   对比的**关键量是 cycles / (格点 × 对)** —— 它和网格大小无关，
 *   所以基线照样能用来算 32×32 需要多少拍。 */
#define SRP_GRID_W   16
#define SRP_GRID_N   (SRP_GRID_W * SRP_GRID_W)   /* 256 */

/* 建网格坐标表。调 srp_acc_pair 之前必须调一次。 */
void srp_init(void);

/* 把一对麦克风的相关序列按延迟几何插值累加进 P：
 *     P[g] += interp( R, τ(g; mi, mj) )      g = 0..SRP_GRID_N-1
 * P 由调用方提供（int32 × SRP_GRID_N），**不清零** —— 多对累加靠这个语义。 */
void srp_acc_pair(const int16_t *r_seq, int mi, int mj, int32_t *p_acc);

/* 只算延迟不累加，供验证用：把每个格点的 τ 打包成 (idx<<4)|frac4 写进 out。
 * 与 srp_acc_pair 走**同一段**几何代码，所以它能证明累加用的延迟是对的。 */
void srp_dump_tau(int mi, int mj, int16_t *out);

#endif /* FW_SRP_H */
