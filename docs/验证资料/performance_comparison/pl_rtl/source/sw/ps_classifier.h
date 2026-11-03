/* ps_classifier.h —— 站 12：随机森林推理内核（PS 侧，Cortex-A9）
 *
 * 三件东西分工，别混：
 *   clf_model.h     训练产物（MATLAB 导出成的 6 张数组），**生成文件，不要手改**
 *   本文件          推理内核，与具体模型无关
 *   ps_clf_test.c   自检程序：拿 clf_model.h 自带的那 8 个样例对一遍答案
 *
 * 为什么随机森林能直接搬上板：**整棵森林就是 6 张数组，推理是一个 while 循环。**
 * 没有 exp / log / sqrt，没有递归，没有 libm。训练时在 MATLAB 里随便用双精度，
 * 推理时只剩"取特征 → 比阈值 → 跳下标"。所以软浮点 ABI（double 走 libgcc）这件事
 * 在推理这一步**不构成瓶颈** —— 真正贵的是站 9 的 FFT。这一条是设计选择，不是巧合：
 * 只有"训练随便贵、推理只要比较"的模型，才适合往这类板子上搬。
 *
 * ⚠ 输入契约（本文件唯一不会自我暴露的用法错误）：
 *   x 必须是 CLF_N_FEAT 维，且**已经按训练脚本的口径归一化过**
 *   （v_db = 20*log10(v / median(v))）。喂原始幅度**不会报错**，只会一直答错。
 *   归一化是站 11 的活，不要塞进这里 —— 这里只管"给一帧归一化好的数，出一个类别"。
 *
 * ⚠ 现在的 18 维特征仓库里还没有（站 11 只产出 4 维包络谱峰），所以本内核
 *   **暂时只能吃 clf_model.h 自带的样例**。接真波形要走：站 11 凑齐 18 维 → 归一化
 *   → clf_predict。
 */
#ifndef PS_CLASSIFIER_H
#define PS_CLASSIFIER_H

#include <stddef.h>        /* NULL —— 本头文件自带依赖，不靠包含它的程序去凑 */
#include "clf_model.h"

/* 类别数、类别名、树数都从 clf_model.h 来，这里不重定义 —— 换模型时只换那个头。 */

/* ------------------------------------------------------------------
 * 推理一帧。x 为 CLF_N_FEAT 维、已归一化的特征；votes_out 可传 NULL。
 * 返回类别号 1..CLF_N_CLASS（1 起，与 clf_node_class 同口径）。
 *
 * 每一步都只有一次比较 + 一次数组取值，栈是常数级。
 *
 * ⚠ **clf_cut_feat 与 clf_node_class 都是 1 起**（MATLAB 习惯），取值前减 1。
 *   这一处写错不会报错、不会越界（0 会读成第 0 维），只会**稳稳地答错** ——
 *   这是整个移植里最容易犯、最难查的一处。ps_clf_test.c 顶部写了排查顺序。
 * ------------------------------------------------------------------ */
static inline int clf_predict(const float *x, int *votes_out)
{
    int votes[CLF_N_CLASS];
    int t, n, c, best, best_v;

    for (c = 0; c < CLF_N_CLASS; c++) {
        votes[c] = 0;
    }

    for (t = 0; t < CLF_N_TREE; t++) {
        n = clf_tree_off[t];              /* 第 t 棵树的根（全局下标） */

        while (clf_cut_feat[n] != 0) {    /* !=0 是分支节点，==0 是叶子 */
            /* 叶子判据只看 cut_feat==0。**别拿 clf_node_class 非零当判据** ——
               导出的格式给每个节点都写了它占多数的类，分支节点上也有值。 */
            if (x[clf_cut_feat[n] - 1] <= clf_cut_point[n]) {
                n = clf_left[n];
            } else {
                n = clf_right[n];
            }
        }
        votes[clf_node_class[n] - 1]++;   /* 叶子投一票（类别号也是 1 起） */
    }

    best = 0;
    best_v = votes[0];
    for (c = 1; c < CLF_N_CLASS; c++) {
        if (votes[c] > best_v) {          /* 严格大于：并列时取小类别号，结果可复现 */
            best_v = votes[c];
            best = c;
        }
    }

    if (votes_out != NULL) {
        for (c = 0; c < CLF_N_CLASS; c++) {
            votes_out[c] = votes[c];
        }
    }
    return best + 1;
}

#endif /* PS_CLASSIFIER_H */
