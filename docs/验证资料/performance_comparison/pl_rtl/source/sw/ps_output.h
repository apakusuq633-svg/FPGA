/* ps_output.h —— 站 13：一次诊断结果的输出（PS 侧，Cortex-A9）
 *
 * 输入是三个已经定下来的量：**方位 / 类别 / 严重程度**。本文件不算法，只负责把它们
 * 用串口打成一行 ASCII。所以它自己也是唯一一处能"看错"的地方，值得单独一个头。
 *
 * ⚠ 三条硬约束，都不是风格问题：
 *
 * 1. **xil_printf 没有 %f。** 板子上的 BSP 那版 printf 不认浮点，也没有宽度修饰符
 *    （%08x / %-12s 会打出垃圾）。所以本文件的结构体里**一个 double 都没有** ——
 *    小数在这里已经变成整数（百分比、毫单位）了。谁要在打印前临时转 double，就会踩到这条。
 *
 * 2. **串口终端按 cp936 解码。** 打中文字节会乱码（也可能吃掉换行）。全 ASCII。
 *
 * 3. **本文件不做几何。** 方位的权威定义在 PL 侧（sw/fw/fw_srp.c 的 16×16 网格，
 *    平场 z = 0.3 m、x/y 各 ±0.2 m，格号 p_arg = gy*16 + gx）。站 13 只把**格号**拆成
 *    (gx, gy) 并报它在扫描面内的**归一化位置**，不复制那张坐标表 —— 两处各存一份
 *    几何必然漂（本仓库的两个交叉检查：RV32_BASE、PDM 窗口，都是这么来的）。
 *    要报毫米/角度的话，由调用方把半宽传进来。
 *
 * 严重程度**目前没有真实出处**：只有站 12 的票占比是真的。结构体里那个字段叫
 * sev_pct 而不是 severity，就是留个记号 —— 它现在装的是"票占比派生的代理量"，
 * 调用方传什么它打什么。别把它当成物理量去解读。
 */
#ifndef PS_OUTPUT_H
#define PS_OUTPUT_H

#include <stdint.h>

#include "xil_printf.h"
#include "clf_model.h"     /* CLF_N_CLASS、clf_class_names —— 类别名跟着模型走 */

/* 一次诊断的全部可打印量。全整数：见文件头第 1 条。 */
struct diag_result {
    int cls;                     /* 1..CLF_N_CLASS，站 12 给的类别号           */
    int votes[CLF_N_CLASS];      /* 各类票数，站 12 的 votes_out              */
    int conf_pct;                /* 赢家票占比 0..100                         */

    int grid;                    /* SRP 峰值格号（PL 侧算的方位）              */
    int grid_w;                  /* 网格边长（格）。<= 0 表示本帧没有方位        */
    int gx, gy;                  /* 由 grid 拆出来的格子坐标                   */
    int azim_pct;                /* −100..+100，扫描面内的归一化位置            */

    int sev_pct;                 /* 0..100，代理量，见文件头                   */
    int med_milli;               /* 特征中位数 ×1000，刻度参照（站 11 的返回）   */
};

/* 格号 → (gx, gy)。PL 侧的 P 是 p[gy*W + gx]，所以整除取商和余数。
 * grid_w <= 0 或 grid 越界时返回 0（＝"这一帧没有方位"），不猜。 */
static int out_split_grid(int grid, int grid_w, int *gx, int *gy)
{
    if (grid_w <= 0 || grid < 0 || grid >= grid_w * grid_w) {
        *gx = 0;
        *gy = 0;
        return 0;
    }
    *gy = grid / grid_w;
    *gx = grid - (*gy) * grid_w;
    return 1;
}

/* 格号 → 扫描面内的归一化位置，−100..+100（对应网格两端）。
 * 与 fw_srp.c 建表那行同形：v = −HALF + j*(2*HALF)/(W−1)，归一化后就是 j/(W−1) 的线性映射。
 * 纯整数，不用浮点。 */
static int out_azim_pct(int idx, int grid_w)
{
    if (grid_w <= 1) {
        return 0;
    }
    return (200 * idx) / (grid_w - 1) - 100;
}

/* 带符号打印：xil_printf 没有 %+d，符号得自己打。
 * 说明符按 cstub 的 format(printf) 属性严格对齐 —— %d 配 int，%u 配 unsigned，
 * 混了会被 -Wformat=2 挡下来（这是好事：板子上打错说明符是运行时乱码，不是编译错）。 */
static void out_signed(int v)
{
    if (v < 0) {
        xil_printf("-%d", (int)(-v));
    } else {
        xil_printf("+%d", (int)v);
    }
}

/* ------------------------------------------------------------------------------------------
 * 打一行机器可读的结果（给上位机 / 日志抓）。字段顺序固定，一个空格一个，无宽度修饰符。
 *
 *   FDIAG cls=<名> conf=<0..100> grid=<格号|none> gx=<n> gy=<n> azim=<±归一化> sev=<0..100> med=<毫>
 *
 * cls 越界时不打名字，打 cls=?，并让调用方从返回值看出这行不可用（返回 0）。
 * ------------------------------------------------------------------------------------------ */
static inline int out_print_diag(const struct diag_result *r)
{
    int ok = 1;
    const char *name = "?";

    if (r->cls >= 1 && r->cls <= CLF_N_CLASS) {
        name = clf_class_names[r->cls - 1];
    } else {
        ok = 0;
    }

    xil_printf("FDIAG cls=%s conf=%u", name, (unsigned)r->conf_pct);
    if (r->grid_w > 0) {
        xil_printf(" grid=%u gx=%u gy=%u azim=", (unsigned)r->grid,
                   (unsigned)r->gx, (unsigned)r->gy);
        out_signed(r->azim_pct);
    } else {
        xil_printf(" grid=none");
    }
    xil_printf(" sev=%u med=%u\r\n", (unsigned)r->sev_pct, (unsigned)r->med_milli);
    return ok;
}

/* ------------------------------------------------------------------------------------------
 * 给人看的两行。第一行"是什么"，第二行"凭什么" —— 排错时想看的正是票数明细，
 * 而票数明细在类别正确的时候也常常是 96/0/3/1 这种不干净的分布，藏起来只会让人
 * 误以为分类器很确定。
 * ------------------------------------------------------------------------------------------ */
static inline void out_print_human(const struct diag_result *r)
{
    int c;

    xil_printf("DIAG: %s (conf %u%%)\r\n",
               (r->cls >= 1 && r->cls <= CLF_N_CLASS) ? clf_class_names[r->cls - 1] : "?",
               (unsigned)r->conf_pct);

    xil_printf("DIR : ");
    if (r->grid_w > 0) {
        xil_printf("cell (%u,%u) of %u x %u, grid %u, azim ",
                   (unsigned)r->gx, (unsigned)r->gy,
                   (unsigned)r->grid_w, (unsigned)r->grid_w, (unsigned)r->grid);
        out_signed(r->azim_pct);
        xil_printf("%%\r\n");
    } else {
        xil_printf("not available (PL did not report a peak cell)\r\n");
    }

    xil_printf("VOTE:");
    for (c = 0; c < CLF_N_CLASS; c++) {
        xil_printf(" %s=%u", clf_class_names[c], (unsigned)r->votes[c]);
    }
    xil_printf("\r\n");
}

#endif /* PS_OUTPUT_H */
