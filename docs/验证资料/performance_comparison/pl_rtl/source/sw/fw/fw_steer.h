/* 转向块（rv32_steer_regs）的固件驱动 —— 「定位 → 定向增强」那根箭头的最后一节。
 *
 * ── 这一段补的是哪个缺口 ────────────────────────────────────────────────────
 * 到 §7 为止，DAS 用的是 fw_das_scene.h 里**编译期钉死**的转向表：它正好指向
 * 目标源，所以 DAS 表现最好，但它与 SRP 报出来的方位**没有任何关系**。
 * 也就是说「SRP 定位 → 波束转过去」这条链在固件里**并没有接上** ——
 * 硬件块（rv32_steer_regs）在 TB 里被验过，固件却从来没驱动过它。
 *
 * 本文件把那一跳接上：写 TARGET → 等 BUSY 落 → 从 RDATA 窗口取 8 路 comp。
 *
 * ── 寄存器（核侧 MMIO 页 0xA000，7 位字地址 → 字节偏移 = 字地址 << 2）────────
 *   0x00 CTRL    W  [0]START [1]EN  ⇒ 要启动写 0x3（CTRL 是整体写，写 0x1 会清 EN）
 *   0x04 STATUS  R  [0]BUSY [1]DONE [2]EN [3]WERR [4]LOCKED [7:5]state [15:8]committed
 *   0x08 ADDR    W  [16:15]SEL(0=LUT 1=COMP) [14:0]IDX
 *   0x10 RDATA   R  读 COMP@IDX 然后 IDX++；**只对 SEL=COMP 有效**
 *   0x14 TARGET  W  定位格号。**写它就触发一次更新**
 *   0x18 CFG     W  [7:0]RAMP_STEP(Q8, 0 = 立即到位) [15:8]HOLD_FRAMES [23:16]CAND_FRAMES
 *   0x1C VER     W/R 哑寄存器
 *
 * ⚠ 迟滞（§26.5.2）会让「写一次 TARGET」**不立即生效**：committed 要连续
 *   CAND_FRAMES 拍落在同一片区域才更新。所以驱动里重复写 TARGET 若干次，
 *   不是冗余 —— 少了它 committed 永远不动，读回来的 comp 是上一条方向的。
 *
 * ⚠ CFG 的 RAMP_STEP 设成 0：渐变（§26.5.1）是为**上板不爆音**用的，而这里是
 *   固件一次性算完一帧的离线场景，要的是「立刻到位」。非 0 的话 comp_out 要
 *   分好几拍才爬到目标值，读回来的是渐变途中的中间值。
 */
#ifndef FW_STEER_H
#define FW_STEER_H

#include <stdint.h>

#include "fw_mem.h"

#define STEER_N_MIC   8

/* 结果区（8 个字），落点见 fw_mem.h 的 FW_STEER_BASE */
#define STEER(i)       (*(volatile int32_t *)(FW_STEER_BASE + 4u * (uint32_t)(i)))

#define STEER_RES_STATUS   0   /* bit0 = 查询成功, bit1 = 块已 LOCKED */
#define STEER_RES_CYCLES   1   /* 受控 DAS 一帧的拍数（0 = 查询失败没跑）*/
#define STEER_RES_CK_REF   2   /* 参照表 g_steer_comp_ref 解包后的校验和（与 CK_NOW 同口径）*/
#define STEER_RES_CK_NOW   3   /* 硬件块报出的 comp 解包后的校验和 */
#define STEER_RES_GRID     4   /* 这次问的是哪个格号（= SRP 峰值格号）*/
#define STEER_RES_DAS_CK   5   /* 受控 DAS 的 y_mix 校验和 */
#define STEER_RES_DAS_PT   6   /* 受控 DAS 的 Σ(y_t>>3)² */
#define STEER_RES_DAS_PO   7   /* 受控 DAS 的 Σ(y_o>>3)² */

/* 把 CFG 设成「立即到位 + 默认迟滞帧数」，并保持 EN=1。 */
void fw_steer_init(void);

/* 查一次转向块：写 grid，等它 commit，再读回 8 路 comp（Q16 样点，有符号）。
   返回 0 成功；非 0 = 失败原因（见 .c 里的 STEER_E_*）。 */
int fw_steer_query(uint32_t grid, int32_t comp[STEER_N_MIC]);

/* 参照方向上的 comp —— 由 fw_das_model.py 生成，**按块自己的 14 位格式打包**
   （{idx[9:0], frac[3:0]}），所以只要 int16 就装得下：8 路一共 16 B。
   DTCM 已经满了（.data + .bss 到 0x27F0，只剩 16 B），这个格式是唯一塞得进去的
   写法 —— 而且它顺带更**对**：参照值和块现场报的值走同一个解包函数，
   不可能出现"两边格式不一致"这种只在数字上显形的错。

   模型那边是拿**真目标方向**按块自己的 14 位截断量化出来的（不是块能查到的格点，
   因为目标方向不落在网格上：y = −0.08 正好落在 gy=4 与 5 的正中间）。

   ⚠ 它和块给的 comp 差一个**每格各自的常数** S_g = t_g.max() − t_g.min()：
       模型 comp_m = t.max() − t_m        块 comp'_m = t_m − t.min()
     ⇒ comp_m = S_g − comp'_m。而 D_m = τ_p^... + comp_m 是常数差不受影响的量，
     所以「表里的 D + comp'_ref − comp'_now」与真值只差一个**8 路公共**的时移 ——
     只挪输出的绝对时刻，不改变对齐。这就是为什么可以拿块报的 comp' 直接做差。 */
extern const int16_t g_steer_comp_ref[STEER_N_MIC];

/* 14 位参照表 → Q16 样点(有符号)。硬件 RDATA 已是 Q16，不再解包。
   ⚠ idx 是 10 位**有符号**：t_m − t_min 按说非负，但 idx 域是有符号的，
     当无符号解释会把 −1 读成 1023（差 1024 个样点）。 */
static inline int32_t fw_steer_unpack14(uint32_t p)
{
    int32_t idx = (int32_t)((p & 0x3FFFu) >> 4);
    if (idx & 0x200) {
        idx -= 0x400;
    }
    return idx * 65536 + ((int32_t)(p & 0xFu) << 12);
}

#endif /* FW_STEER_H */
