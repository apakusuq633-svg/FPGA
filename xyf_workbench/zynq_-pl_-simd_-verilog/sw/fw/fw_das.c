/* DAS 波束形成器 —— 固件定点内核。对应 README §26.1。
 *
 *     y[n] = Σ_m w_m · x_m[n − τ_m]        w_m = 1/8（等权）
 *
 * ── 为什么固件里没有"每通道一条延迟线" ──────────────────────────────────────
 * 把「源 p 的到达延迟 τ_m^p」与「转向 θ̂ 的补偿 comp_m = τmax^θ̂ − τ_m^θ̂」合并：
 *
 *     a_m[n] = s_p( n − (τ_m^p + comp_m^θ̂) ) = s_p( n − D_m )
 *
 * D_m 是**常数**，所以「已对齐的通道」能从源信号**一次插值**直接算出来，
 * 不需要为每路各存一条延迟线。DTCM 只剩两张 8 元素表（fw_das_scene.h）。
 *
 * 关键性质（模型里断言过）：
 *   目标源 + 对准目标 ⇒ 8 个 D_m 全相等 ⇒ 完全对齐 ⇒ 求和拿 8 倍幅度
 *   干扰源 + 对准目标 ⇒ 8 个 D_m 互异 ⇒ 不对齐   ⇒ 求和时抵消
 *
 * ── 定点约定：与 scripts/golden/fw_das_model.py 一字不差 ───────────────────
 *   延迟 Q16 样点；idx = D>>16；fr4 = (D>>12)&0xF；v = v0 + ((v1−v0)·fr4 >> 4)
 *   源在 k<0 处一律 0（因果）
 *   Σ 后 y = floor((S + 4) / 8)      ← 注意是 **floor**，C 的 `/` 是向零截断，
 *                                      两者对负数不同 —— 已提到 fw_scene.h 的 fw_fd8，两个内核共用
 *   功率和定标：Σ (y >> 3)²，避免 int32 溢出（512 × 32767² 放不下；见下面说明）
 *
 * ⚠ 源信号必须是**有雪崩的 hash**（mix32），不能是 LCG。LCG 三步是仿射的 ⇒
 *   生成的是锯齿波 ⇒ 干扰的 8 路通道相关 0.97 ⇒ 延迟解不了相关 ⇒ DAS 反而变差。
 *   这个坑在 Python 侧踩过一次（DAS −0.59 dB，本该 +6.5 dB），见 fw_das_model.py。
 */
/* ⚠ 必须放在**所有 include 之前**：fw_das.h 也会把 fw_das_scene.h 带进来，
   而这个宏要在那份头文件被**第一次**读到时就已经定义好（头文件有 include guard，
   第二次包含不会重新求值）。这个文件是 g_steer_comp_ref 的**唯一**定义处 ——
   它在 C 里是外部链接的正经符号，别的 TU（fw_main.c / fw_steer.c）只拿到
   fw_steer.h 里的 extern 声明。定义放这儿是因为本文件本来就用那两张表，
   不会产生"声明了没用"的告警。 */
#define FW_DAS_SCENE_DEFINE_COMP_REF

#include <stdint.h>

#include "fw_das.h"
#include "fw_das_scene.h"
#include "fw_scene.h"     /* mix32/scaled_src/interp_src/interp_noise —— 与 GSC 共用 */
#include "fw_mem.h"
#include "fw_steer.h"     /* g_steer_comp_ref —— 受控那趟要用 */

#define RES(i)  (*(volatile int32_t *)(FW_RES_BASE + 4u * (uint32_t)(i)))

/* Σ (y>>3)²：直接累加 y² 会溢出（512 × 32767² ≈ 5.5e11 > int32），
   先右移 3 位再平方，512 × (32767>>3)² ≈ 8.6e8，安全。
   代价是小数被量化 —— 报 dB 时对**分子分母同口径**，比值仍可用；
   逐位验证靠的是校验和（覆盖每一个输出样点），不是这两个功率和。 */
static inline int32_t powacc(int32_t y)
{
    int32_t q = y >> 3;
    return q * q;
}

/* 一趟的输出。抽成结构体是为了让"固定转向"和"受控转向"两趟**共用同一段
   累加代码** —— 两份拷贝迟早会分叉，而分叉的表现是"其中一趟的数字不对"。 */
typedef struct {
    uint32_t ck, wck;
    int32_t  p_t, p_o, p_m, p_mo;
    int      ndiff;
} das_metrics;

/* 内核本体。cnow 非 NULL 时按
       D_m = 表里的 D_m + (comp'_ref[m] − comp'_now[m])
   现场改延迟（口径推导见 fw_steer.h 末尾）；为 NULL 时就是场景表原样。
   cr 是**打包**的参照表（14 位，见 fw_steer.h），和 cnow 一样过 fw_steer_unpack14。

   ⚠ 两条表在**进样点循环之前**就改好：adj 只和 m 有关，放进 n 循环里会多算
     4096 次，而且每帧多一次指针判空。 */
static void das_kernel(const int32_t *cnow, const int16_t *cr, das_metrics *r)
{
    uint32_t dt[DAS_N_CH], di[DAS_N_CH];
    int32_t p_t = 0, p_o = 0, p_m = 0, p_mo = 0;
    uint32_t ck = 0u, wck = 0u;
    int ndiff = 0;

    for (int m = 0; m < DAS_N_CH; m++) {
        int32_t adj = 0;
        if (cnow != 0) {
            adj = fw_steer_unpack14((uint32_t)(uint16_t)cr[m]) - cnow[m];
        }
        dt[m] = (uint32_t)((int32_t)g_das_d_target[m] + adj);
        di[m] = (uint32_t)((int32_t)g_das_d_interf[m] + adj);
    }

    for (int m = 1; m < DAS_N_CH; m++) {
        if (g_das_d_interf[m] != g_das_d_interf[0]) { ndiff = 1; }
    }

    for (int n = 0; n < DAS_N_SAMP; n++) {
        int32_t s_t = 0, s_i = 0, s_n = 0;

        for (int m = 0; m < DAS_N_CH; m++) {
            s_t += interp_src(dt[m], n, SEED_TGT, AMP_TGT);
            s_i += interp_src(di[m], n, SEED_IFR, AMP_IFR);
            s_n += interp_noise(dt[m], n, m);
        }

        /* ⚠ 三条分量要**各自** floor 再相加，不能先加再 floor —— 与模型的
           `_sum(ch_i) + _sum(ch_n)` 对齐。floor 不是线性的，先加会让负样本差 1 LSB。 */
        int32_t y_t = fw_fd8(s_t);
        int32_t y_o = fw_fd8(s_i) + fw_fd8(s_n);
        int32_t y   = y_t + y_o;

        if (y >  32767) { y =  32767; }
        if (y < -32768) { y = -32768; }

        ck  = (ck  + (uint32_t)y) & 0xFFFFFFFFu;
        wck = (wck + (uint32_t)(y * (n + 1))) & 0xFFFFFFFFu;

        p_t  += powacc(y_t);
        p_o  += powacc(y_o);

        /* 单麦基线：第 0 路，不做任何空间处理。目标、其余各算各的 */
        int32_t mic_t = interp_src(dt[0], n, SEED_TGT, AMP_TGT);
        int32_t mic_o = interp_src(di[0], n, SEED_IFR, AMP_IFR)
                      + interp_noise(dt[0], n, 0);
        p_m  += powacc(mic_t);
        p_mo += powacc(mic_o);
    }

    r->ck = ck;   r->wck = wck;
    r->p_t = p_t; r->p_o = p_o;
    r->p_m = p_m; r->p_mo = p_mo;
    r->ndiff = ndiff;
}

void fw_das_run(void)
{
    das_metrics r;
    das_kernel(0, 0, &r);
    RES(DAS_RES_CKSUM)   = (int32_t)r.ck;
    RES(DAS_RES_WCKSUM)  = (int32_t)r.wck;
    RES(DAS_RES_P_TARGET)  = r.p_t;
    RES(DAS_RES_P_OTHER)   = r.p_o;
    RES(DAS_RES_P_MIC)     = r.p_m;
    RES(DAS_RES_P_MIC_OTH) = r.p_mo;
    RES(DAS_RES_NDIFF)     = r.ndiff;
}

/* 受控那趟：转向方向由硬件块现场报出来，不是编译期钉死的。
 *
 * ⚠ 这里**必须**用 das_kernel 而不是另写一遍 —— 两趟的定点口径（三条分量各自
 *   floor 再相加、Σ 后 floor((S+4)/8)、>3 位再平方）必须逐字相同，否则
 *   「受控比固定好还是差」这个比较里混进了"口径差"，结论就不成立。
 *
 * 结果写进 FW_STEER_BASE（见 fw_mem.h；那是 .fwgsc 尾巴里空着的 8 个字），
 * **不碰 RES 块** —— 21..31 已被"固定转向"那趟和其他内核占满，
 * 覆盖掉的话 tb_fw_das / tb_fw_gsc 会一起变红，而且看不出是谁写的。 */
void fw_das_run_steered(const int32_t *comp_now)
{
    das_metrics r;
    das_kernel(comp_now, g_steer_comp_ref, &r);
    STEER(STEER_RES_DAS_CK) = (int32_t)r.ck;
    STEER(STEER_RES_DAS_PT) = r.p_t;
    STEER(STEER_RES_DAS_PO) = r.p_o;
}
