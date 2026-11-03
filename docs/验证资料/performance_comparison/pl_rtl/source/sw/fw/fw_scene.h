/* 场景/源信号/定点插值 —— DAS 与 GSC 共用。
 *
 * 抽出来的理由：这两个内核各自需要"按 Q16 延迟从源信号插值出已对齐的通道"，
 * 而**它必须逐位一致**。写两份的直接后果是日后改了一份忘了另一份，
 * 而症状是"两个内核在同一场景下算出的东西对不上"，很难查。
 *
 * ⚠ 定点口径的**唯一出处**是 scripts/golden/fw_das_model.py。
 *   这里每一条移位/取整都要和那边一字不差。
 */
#ifndef FW_SCENE_H
#define FW_SCENE_H

#include <stdint.h>

/* ── 源信号（三方照抄：固件 / Python 模型 / TB）─────────────────────────────
 * ⚠⚠ 必须是**有雪崩的 hash**，不能是 LCG。
 *   一开始写的是「seed = LCG_C + k，再走 3 步 LCG」—— 三步 LCG 是**仿射**的
 *   （s -> A³s + K），整体仍是 k 的仿射函数 ⇒ s(k+1) − s(k) 是常数
 *   ⇒ 生成的是**锯齿波**。后果不是"看着不对"，而是干扰源的 8 路通道
 *   **两两相关系数 0.97**，延迟几个样点根本解不了相关，DAS 求和反而把干扰放大
 *   （实测 −0.59 dB，本该 +6.5 dB）。 */
#define MIX_A       0x7FEB352Du
#define MIX_B       0x846CA68Bu
#define SEED_TGT    0x5EED0001u
#define SEED_IFR    0x5EED0002u
#define SEED_NOISE0 0x5EED1000u
#define AMP_TGT     8000
#define AMP_IFR     8000
#define AMP_NSE     250

/* 定义在 fw_scene.c。**不要写成 static inline** —— 那会在每个 .c 里各生成一份，
   .text 会冲破 0x2000。理由与后果见 fw_scene.c 头部。 */
uint32_t mix32(uint32_t x);
int32_t  scaled_src(uint32_t seed, int32_t k, int32_t amp);
int32_t  interp_src(uint32_t D, int32_t n, uint32_t seed, int32_t amp);
int32_t  interp_noise(uint32_t D, int32_t n, int m);

/* ── cycle 计数器（CSR 0xC00）──────────────────────────────────────────────
 * ⚠ 读出来之后**不能马上用**：CSR 读的结果没有前递，紧随其后的那条指令读到的是 x。
 *   实测（tb_fw_smoke 第一版）：相隔 0 条 → x；相隔 6 条 → 正确。
 *   所以 csrr 后面塞六条 nop。⚠ 写成 `addi %0,%0,0` ×3 是**错的** ——
 *   它依赖 %0，只会把 x 一路传下去。根治要在核的 CSR 路径加前递，见 docs/issues/030。
 *
 * 这是"头文件里放 static inline"的**例外**：只有 ~10 条指令，跨两个 TU 展开的
 * 代价可以忽略；而它是 asm，做成 extern 反而多一次调用开销（每次多 6 拍 nop 已经够贵）。
 * 大函数（插值/mix32）不适用这条例外，见 fw_scene.c 头部。
 *
 * ⚠⚠ **只给 RISC-V 用。** sw/ps_only.c（README §34 的 PS-only 对照）要把同一批
 *   内核编到 Cortex-A9 / x86 上，那两个平台上 `csrr` 根本不存在 —— 那边在
 *   include 本文件之前定义 `FW_RDCYCLE_OVERRIDE` 并给出自己的实现。
 *   六条 nop 是**RISC-V 核那条没有前递的 CSR 通路**的补丁，别的平台不需要。 */
#ifdef FW_RDCYCLE_OVERRIDE
/* 非 RISC-V 目标：由**外部**提供一个 rdcycle（sw/ps_only.c 里按平台分派）。
   ⚠ 必须放在头里声明、而不是各 TU 各写一份 static inline —— fw_gsc.c 与
     fw_das.c 也用 rdcycle，而它们是**独立的编译单元**，只有声明在这里才
     保证三个 TU 用的是同一个实现。定义成宏的时候最容易漏的正是这一条：
     编译能过、跑起来每个 TU 数的是不同的东西。 */
uint32_t rdcycle(void);
#else
static inline uint32_t rdcycle(void)
{
    uint32_t c;
    __asm__ volatile("csrr %0, cycle\n\t"
                     "nop\n\t" "nop\n\t" "nop\n\t" "nop\n\t" "nop\n\t" "nop"
                     : "=r"(c));
    return c;
}
#endif

/* 固定波束形成的等权求和：floor((S + M/2) / M)，M = 8。
   ⚠ C 的 `/` 向零截断、Python 的 floor_divide 向负无穷 —— 负数上差 1，
     是这个内核里最容易出的逐位不一致，所以显式写成 floor。 */
static inline int32_t fw_fd8(int32_t S)
{
    int32_t t = S + 4;
    return (t >= 0) ? (t >> 3) : ~((~t) >> 3);
}

#endif /* FW_SCENE_H */
