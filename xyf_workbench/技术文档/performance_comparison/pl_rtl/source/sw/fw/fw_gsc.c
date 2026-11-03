/* GSC —— 固件定点内核。对应 README §26.3。
 *
 *     d(n) = Σ_m w_m a_m(n)                  固定波束形成（= DAS 那一条）
 *     u_j(n) = a_j(n) − a_{j+1}(n)           阻塞矩阵：成对相减（§26.3.2 第一版）
 *     y(n) = Σ_j Σ_k W_j[k]·u_j(n−k)
 *     e(n) = d(n) − y(n)
 *     W_j[k] += μ·e(n)·u_j(n−k) / (δ + Σ_j‖u_j(n)‖²)
 *
 * 定点口径的**唯一出处**是 scripts/golden/fw_gsc_model.py。
 *
 * ── 为什么要一趟算三条 ──────────────────────────────────────────────────────
 * GSC 是**时变**的，SNR 的分子分母必须来自**同一条 W(n) 轨迹**（否则比值没意义）。
 * 存轨迹要 7×16×512×4 B = 229 KB，DTCM 只有 16 KB。所以改成**一趟同时算
 * 「混合 / 目标 / 其余」三条**，而**更新只看混合那一路** ——
 * 三条共用同一个 W，轨迹自然只有一条。e_t / e_o 只用来报数。
 *
 * ⚠⚠ 第一版写成「三遍各自用本遍的滤波输出算误差去更新」。三遍滤波对象不同
 *   ⇒ y 不同 ⇒ e 不同 ⇒ **W 轨迹各不相同**，SNR 的分子分母来自三个不同的滤波器。
 *   是三遍 W 的逐位断言把它抓出来的。**更新的误差必须永远取自混合那一路。**
 *
 * ── 定点约定（与模型一字不差）──────────────────────────────────────────────
 *   回归量 h = (u >> 6)，**滤波 / 范数 / 更新三处共用同一个值**
 *     ← 第一版让滤波用 u>>7、更新用完整的 u —— 两者不是同一个回归量，
 *       LMS 的梯度方向建立在 y = ΣW·h 上，实际算的是 ΣW·(h>>7)，
 *       自适应被系统性带偏。实测同一 μ 下浮点 +0.56 dB、定点 −0.13 dB。
 *   W 是 Q12（权值 = W/4096），限幅 ±8192（= ±2.0）
 *   y = (Σ W·h) >> 6
 *   nrm = 1 + Σ h²
 *   ΔW = (3 · (e>>1) · h) / nrm    ← **倒数替换乘法**（原来是除法）：nrm 对 112 个
 *     抽头是同一个 ⇒ 每个样点一次 `0xFFFFFFFFu/nrm`，其余 111 次走 mulhu（单拍）。
 *     除法是 32 次迭代的恢复余数（~34 拍），这一项原来占 GSC 的 ~26%。
 *     误差：r·nrm = 2³²+δ, δ<nrm ⇒ a·r/2³² < a/nrm + 0.5 ⇒ **≤1 个最低位、恒偏大**。
 *     代价是它**有偏**（不是无偏噪声）⇒ 必须量 SNR，见 docs/measurements.md §7.6。
 *
 * ⚠ 抽头数 **16**（不是 32/64）：NLMS 收敛时间 ∝ L/μ，一帧只有 512 个样点，
 *   抽头越多越来不及收敛。实测 L=16 相对 DAS +0.25 dB、L=32 只有 +0.16 dB。
 *   浮点扫描同规律（L=32 最好，64/128 反而差）。见 fw_mem.h 的内存账。
 */
#include <stdint.h>

#include "fw_gsc.h"
#include "fw_das_scene.h"
#include "fw_scene.h"
#include "fw_mem.h"
#include "fw_plat.h"     /* FW_HAVE_HW —— 阵列三条宏的开关 */

#define RES(i)  (*(volatile int32_t *)(FW_RES_BASE + 4u * (uint32_t)(i)))
#define EXTRA(i) (*(volatile int32_t *)(FW_GSC_EXTRA + 4u * (uint32_t)(i)))

#define GSC_N        512
#define GSC_NCH      8
#define GSC_REF      (GSC_NCH - 1)      /* 7 */
#define GSC_L        16

#define Q_SHIFT      6
#define ACC_SHIFT    6                  /* = 12 − Q_SHIFT */
#define UPD_SHIFT    1
#define MU_NUM       3                  /* μ_eff = MU_NUM/64，扫描取最优 */
#define W_LIM_Q12    8192               /* ±2.0 —— 实测 |W|max 只到 115/4096 */

/* ── 阵列通路（mode=1）的常数。设计见 docs/gsc_vec_design.md ──────────────
 *
 * 7 路参考**交织进一条延迟线**：位置 7n+j 放 ref j 的回归量。
 *   ⇒ h_j(n−k) = x(7n+j−7k)，而阵列算 x(nn−t)、nn = 写指针−1
 *   ⇒ 令 t = (6−j) + 7k 就对上了 —— 7 路 × 16 抽头塌成**一个 112 抽头的 FIR**。
 * 系数只放 W0 一套、延迟线只用 3 条（mix / x'[0]=tgt / x'[1]=oth）。
 *
 * 定标（**唯一出处是 scripts/golden/fw_gsc_vec_model.py**，改这里必须同步改那边）：
 *   延迟线存   x = h << VS_SHIFT        （VS_SHIFT=5；|h|≤511 ⇒ |x|≤16352 < 2^15 ✓）
 *   系数存     C_eff = W（有效系数 = 24 位存储的高 16 位）⇒ 存 W<<8
 *   滤波输出   A = Σ C·x = 32·Σ W·h     ⇒ y = A >> (VS_SHIFT + ACC_SHIFT) = A >> 11
 *   更新       VUPD： C += (g·x) >> 16  ⇒ ΔC = (g·h)>>11，要它 = K·h/nrm
 *              ⇒ g = K << 11 / nrm     （实测 512 样点 0 次溢出，见 §5.1）
 *   ⚠ 阵列的系数存储比标量细 8 位小数 ⇒ **两版指纹不能共用**，本来就不该逐位相同。
 */
#define VS_SHIFT     5
#define VS_NTAP      120                /* 8 的倍数，≥ 113；空位系数置 0 */
#define VS_PASS      15                 /* = VS_NTAP/8，LEN = VS_PASS−1 = 14 */
#define VS_RES_SHIFT (VS_SHIFT + ACC_SHIFT)   /* = 11 */

/* 自定义指令（opcode 0x0B）。编码定义见 rtl/decode/rv32_decoder.v 的 OP-V 段：
 *   funct3 = 0 PUSH / 1 VRED / 2 VUPD / 3 VMUL
 *   funct7 = data×0x08 | ch0×0x10 | ch1×0x20 | coef×0x04 | acc×0x02
 *   rs2    = LEN（趟数−1），rd = 结果寄存器，rs1 = 标量（VUPD 的 g）
 * ⚠ LEN 是 6 位（{instr[25], instr[24:20]}），模式位不是 5 位 —— 按 5 位取会静默丢通道号。 */
#if !FW_HAVE_HW
/* 非 RISC-V 目标（Cortex-A9 的 PS-only 基线、host 的定点模型）：
   阵列不存在，这三条宏**变空操作**，同时 fw_gsc_run 把 mode 钉成 0。
   ⚠ 两者必须一起改：只把宏变空、mode 还让它进 1，那一路就会拿延迟线里的
     垃圾算出一个"看起来像滤波器输出"的数 —— 不报错，只是不算。
   好处之一是基线镜像的机器码里连编码都不剩，见 gen_acoustic_image.py。 */
#define VPUSH(v, F7) ((void)(v))
#define VRED(rd, F7) ((rd) = 0)
#define VUPD(g, F7)  ((void)(g))
#else
#define VPUSH(v, F7) __asm__ volatile(".insn r 0x0B, 0, " F7 ", x0, %0, x0" :: "r"(v))
/* ⚠⚠ **LEN 不是立即数 —— 它是 rs2 的寄存器号。**
   `rv32_core.v:646` 是 `idex_vec_len = idex_imm[5:0]`，而 `imm = {instr[30], instr[29:20]}`
   ⇒ LEN = `instr[24:20]` = **rs2 的寄存器号**。
   所以要用 LEN=14 就必须写一个**编号为 14 的寄存器**（`x14`），并在 clobber 里声明它。
   写成 `"r"(14)` 让 GCC 随便挑寄存器 ⇒ LEN 变成那个寄存器号，**静默算错**。
   （实测踩过：`tb_gsc_vec_map` 里我给的是**端口** `len`，所以没暴露；一进固件就错。）
   ⚠ x14 的值其实用不到，只有**编号**有意义 —— 但仍然要 clobber，否则 GCC 会以为它没变。 */
#define VS_LEN_REG "x14"
#define VRED(rd, F7) \
    __asm__ volatile(".insn r 0x0B, 1, " F7 ", %0, x0, " VS_LEN_REG \
                     : "=r"(rd) : : VS_LEN_REG)
#define VUPD(g, F7) \
    __asm__ volatile(".insn r 0x0B, 2, " F7 ", x0, %0, " VS_LEN_REG \
                     :: "r"(g) : VS_LEN_REG)
#define VF7_X     "0x00"                /* w 系数 + x 线（mix） */
#define VF7_P0    "0x08"                /* w 系数 + x′[0]（tgt） */
/* ⚠⚠ oth 走 **ch=2（x′[2]）而不是 ch=1（x′[1]）**。
   原因：`rv32_vec_unit.v:186` 是
       wire [CAW-1:0] c_waddr = (ch3_q[0] ? W1_BASE : W0_BASE) + {2'b0, p3_q};
   —— **`ch[0]` 选的是 `w` 系数 bank，不只是延迟线**。所以
       ch=0(或 2) → x 线/x′[0]/x′[2] 配 **W0**；ch=1(或 3) → x′[1]/x′[3] 配 **W1**。
   GSC 的三条滤波**必须共用同一套 W**（它们是同一个自适应滤波器的三次求值），
   所以三条都要落在 **W0**：mix=data0、tgt=data1/ch0、oth=**data1/ch2**。
   ⚠ 用 ch=1 的后果：读/写的是**从没初始化过的 W1** ⇒ 结果全是 X。
     实测指纹：`tb_gsc_vec_map` 里 x′[0] 给 61440、x′[1] 给 **x**。 */
#define VF7_P1    "0x28"                /* w 系数 + x′[2]（oth）—— 见上，不能用 ch=1 */
#endif /* FW_HAVE_HW */

/* 三条延迟线（int16）与权值（int16，限幅 ±8192 装得下 15 位）都在 FW_GSC_BASE */
#define H_BYTES      (GSC_REF * GSC_L * 2)          /* 224 */
/* ⚠ 写成宏而不是 `static int16_t *const`：FW_GSC_BASE 在重定位模式下是
   运行期才能求值的（sw/ps_only.c 的 fw_mem_scratch），而文件作用域的
   static 初始化式必须是编译期常量。原地址是常量时两者生成同样的代码。 */
#define h_mix  ((int16_t *)FW_GSC_BASE)
#define h_tgt  ((int16_t *)(FW_GSC_BASE + H_BYTES))
#define h_oth  ((int16_t *)(FW_GSC_BASE + 2u * H_BYTES))
#define w_q12  ((int16_t *)(FW_GSC_BASE + 3u * H_BYTES))

/* 滤波：acc = Σ_j Σ_k W[j][k]·h[j][k]，再 >>ACC_SHIFT 回到 e 的量纲。
   溢出账：|W| ≤ 8192、|h| ≤ 32767>>6 = 511 ⇒ 每项 ≤ 4.2e6，112 项 ≤ 4.7e8 < 2^31 ✓ */
static inline int32_t filt(const int16_t *h)
{
    int32_t acc = 0;
    for (int j = 0; j < GSC_REF; j++) {
        const int16_t *hr = h + j * GSC_L;
        const int16_t *wr = w_q12 + j * GSC_L;
        for (int k = 0; k < GSC_L; k++) {
            acc += (int32_t)wr[k] * (int32_t)hr[k];
        }
    }
    return acc >> ACC_SHIFT;
}

/* 推入新样点：k=0 是最新。存的是**回归量**（已 >>Q_SHIFT），不是原始 u */
static inline void push(int16_t *h, int32_t u)
{
    for (int k = GSC_L - 1; k > 0; k--) { h[k] = h[k - 1]; }
    h[0] = (int16_t)u;
}

void fw_gsc_run(int mode)
{
    int32_t p_t = 0, p_o = 0;
    uint32_t ck_t = 0u, wck_t = 0u, ck_mix = 0u;
    int32_t wsum = 0;
    /* 内部分段计时：成本构成猜错过两次，改成让固件自己报 */
    uint32_t c_scene = 0;

#if !FW_HAVE_HW
    /* 这台机器上没有阵列 ⇒ 只可能走标量。钉死在这里，与上面三条空宏配套：
       只把宏变空而让 mode=1 进来，读的是从没写过的延迟线 ⇒ 安静地算错。 */
    (void)mode;
    mode = 0;
#endif

    for (int i = 0; i < GSC_REF * GSC_L; i++) {
        h_mix[i] = 0; h_tgt[i] = 0; h_oth[i] = 0; w_q12[i] = 0;
    }

    for (int n = 0; n < GSC_N; n++) {
        int32_t a_mix[GSC_NCH], a_tgt[GSC_NCH], a_oth[GSC_NCH];
        int32_t s_mix = 0, s_t = 0, s_o = 0;
        uint32_t t0, t1;

        t0 = rdcycle();
        for (int m = 0; m < GSC_NCH; m++) {
            int32_t t = interp_src(g_das_d_target[m], n, SEED_TGT, AMP_TGT);
            int32_t iv = interp_src(g_das_d_interf[m], n, SEED_IFR, AMP_IFR);
            int32_t nz = interp_noise(g_das_d_target[m], n, m);
            a_tgt[m] = t;
            a_oth[m] = iv + nz;
            a_mix[m] = t + iv + nz;
            s_t += t;
            s_o += iv + nz;
            s_mix += a_mix[m];
        }

        t1 = rdcycle(); c_scene += t1 - t0;

        int32_t d_mix = fw_fd8(s_mix);
        int32_t d_t = fw_fd8(s_t);
        int32_t d_o = fw_fd8(s_o);
        /* 阻塞矩阵（成对相减，再压回 int16 量程）后推入延迟线。
           ⚠ 两条路径的推法不同，但**同一个值**：
              mode=0 只推 DTCM（标量滤波用）；
              mode=1 还把同一个值推给阵列（交织流），DTCM 只推 h_mix（范数要用）。 */
        if (mode == 0) {
            for (int j = 0; j < GSC_REF; j++) {
                push(h_mix + j * GSC_L, ((a_mix[j] - a_mix[j + 1]) >> 1) >> Q_SHIFT);
                push(h_tgt + j * GSC_L, ((a_tgt[j] - a_tgt[j + 1]) >> 1) >> Q_SHIFT);
                push(h_oth + j * GSC_L, ((a_oth[j] - a_oth[j + 1]) >> 1) >> Q_SHIFT);
            }
        } else {
            for (int j = 0; j < GSC_REF; j++) {
                int32_t hm = ((a_mix[j] - a_mix[j + 1]) >> 1) >> Q_SHIFT;
                push(h_mix + j * GSC_L, hm);         /* 只给范数：阵列不给 Σx² */
                VPUSH(hm << VS_SHIFT, VF7_X);
                VPUSH(((((a_tgt[j] - a_tgt[j + 1]) >> 1) >> Q_SHIFT) << VS_SHIFT), VF7_P0);
                VPUSH(((((a_oth[j] - a_oth[j + 1]) >> 1) >> Q_SHIFT) << VS_SHIFT), VF7_P1);
            }
        }

        int32_t y_mix, e_t, e_o;
        if (mode == 0) {
            y_mix = filt(h_mix);
            e_t   = d_t - filt(h_tgt);
            e_o   = d_o - filt(h_oth);
        } else {
            /* 阵列滤波：A = Σ C·x = 32·Σ W·h（x = h<<VS_SHIFT）⇒ y = A >> (VS_SHIFT+ACC_SHIFT) */
            int32_t am, at, ao;
            VRED(am, VF7_X);
            VRED(at, VF7_P0);
            VRED(ao, VF7_P1);
            y_mix = am >> VS_RES_SHIFT;
            e_t   = d_t - (at >> VS_RES_SHIFT);
            e_o   = d_o - (ao >> VS_RES_SHIFT);
        }
        int32_t e_mix = d_mix - y_mix;

        /* 范数：**两条路径共用**（阵列的 VMUL 是 Σ|x| 不是 Σx²，给不了范数） */
        int32_t nrm = 1;
        for (int i = 0; i < GSC_REF * GSC_L; i++) {
            nrm += (int32_t)h_mix[i] * (int32_t)h_mix[i];
        }
        int32_t K = MU_NUM * (e_mix >> UPD_SHIFT);

        if (mode == 0) {
            /* 倒数替换除法：分母 nrm 对 112 个抽头是同一个，所以每个样点只做**一次**
               `0xFFFFFFFFu/nrm`（34 拍的恢复余数除法），其余换成单拍的 mulhu。
               口径与 scripts/golden/fw_gsc_model.py 的 _recip/_rmul 一字不差。
               ⚠ nrm=1 时 r 回绕成 0 ⇒ ΔW=0 —— 而 nrm=1 意味着全部 h=0 ⇒ 本来就该是 0。 */
            uint32_t rcp = 0xFFFFFFFFu / (uint32_t)nrm + 1u;
            for (int i = 0; i < GSC_REF * GSC_L; i++) {
                int32_t  P = K * (int32_t)h_mix[i];
                uint32_t a = (P < 0) ? (uint32_t)(-P) : (uint32_t)P;
                uint32_t q = (uint32_t)(((uint64_t)a * (uint64_t)rcp) >> 32);   /* = mulhu */
                int32_t  d = (P < 0) ? -(int32_t)q : (int32_t)q;
                int32_t nw = (int32_t)w_q12[i] + d;
                if (nw >  W_LIM_Q12) { nw =  W_LIM_Q12; }
                if (nw < -W_LIM_Q12) { nw = -W_LIM_Q12; }
                w_q12[i] = (int16_t)nw;
            }
        } else {
            /* 更新交给阵列的 VUPD： C += ((g·x) >> **15**) << 8
                 ⇒ ΔC_eff = (g·h) >> (15 − VS_SHIFT)
               要它等于 K·h/nrm ⇒ g = K·2^(15−VS_SHIFT)/nrm。口径见 fw_gsc_vec_model.py。
               ⚠⚠ 指数里的 **15** 来自 RTL 的 `gmul >>> 15`（rv32_vec_unit.v:280）。
                 那里注释写"取高 16 位"，但代码是 [30:15] —— **按注释改成 16 会让步长翻倍**。
                 实测指纹：g=x=256 时每抽头 +2 不是 +1（tb_gsc_vec_map）。
               ⚠ 从 X 出发 VUPD 永远回不到 0 —— 系数 bank 必须先由 PS/TB 清 0（§6.0）。
               ⚠ 用 int32 算（写 int64 会拉进 __divdi3，本工程是 nostdlib）。
                 `K<<10` 溢出 int32 的界是 |K| ≥ 2^21 = 2,097,152，先把 K 钳在那里；
                 实测本场景 |K| 最大 ~16,000，**这条钳位一次都没触发** —— 模型里有同样的钳位。 */
            int32_t Kc = K;
            if (Kc >  2097152) { Kc =  2097152; }
            if (Kc < -2097152) { Kc = -2097152; }
            int32_t g = (Kc << (15 - VS_SHIFT)) / nrm;
            if (g >  32767) { g =  32767; }
            if (g < -32768) { g = -32768; }
            VUPD(g, VF7_X);
        }

        /* 其余各段的占比由「总拍数 − 场景生成」推出来 —— 少一次 rdcycle 展开，
           省 ~8 条指令 × 6 次/样点 的 .text（上一版就是被这个顶过 0x2000 的） */

        /* 指纹（在 e_t / e_o 上 —— 它们才是 SNR 的分子分母） */
        ck_t  = (ck_t  + (uint32_t)e_t) & 0xFFFFFFFFu;
        wck_t = (wck_t + (uint32_t)(e_t * (n + 1))) & 0xFFFFFFFFu;
        ck_mix = (ck_mix + (uint32_t)d_mix) & 0xFFFFFFFFu;
        int32_t qt = e_t >> 3, qo = e_o >> 3;
        p_t += qt * qt;
        p_o += qo * qo;
    }

    for (int i = 0; i < GSC_REF * GSC_L; i++) { wsum += (int32_t)w_q12[i]; }

    if (mode == 0) {
        RES(GSC_RES_E_CKSUM)  = (int32_t)ck_t;
        RES(GSC_RES_E_WCKSUM) = (int32_t)wck_t;
        EXTRA(0) = p_t;
        EXTRA(1) = p_o;
        EXTRA(2) = (int32_t)ck_mix;
        EXTRA(3) = wsum;
        EXTRA(4) = (int32_t)c_scene;
    } else {
        /* ⚠ 阵列那趟**不能写 RES** —— main 先跑标量再跑阵列，写进去会把标量的指纹冲掉。
           所以第二组结果全放 FW_GSC_EXTRA。拍数由 main 用 rdcycle 包住后写 [5]。
           ⚠ w_q12 在阵列通路里**不更新**（权值在阵列的 BRAM 里，固件没有镜像），
             所以这里不报 wsum —— 阵列那路的指纹是 p_t/p_o。 */
        EXTRA(GSC_X_VEC_P_TARGET) = p_t;
        EXTRA(GSC_X_VEC_P_OTHER)  = p_o;
    }
}
