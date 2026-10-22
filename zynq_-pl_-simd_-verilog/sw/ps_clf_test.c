/* ps_clf_test.c —— 站 12 自检：把 clf_model.h 自带的那几个样例喂进 clf_predict，
 * 和 MATLAB 的答案对一遍。
 *
 * 这个文件要回答的问题只有一个：**MATLAB 里训出来的那 100 棵树，搬到板上有没有搬错。**
 *
 * ⚠ 分清它验的是什么、不是什么：
 *     本文件通过  ⇒ 推理内核与导出格式一致（数组下标、1 起/0 起、叶子判据都对）
 *     本文件通过  ⇏ 对真波形也能分类 —— 那要等站 11 把 18 维特征凑齐、归一化对
 *   样例是**训练集里的样本**，所以"8/8"只证明搬运没错，**不证明泛化**。
 *
 * 它不碰任何硬件寄存器（没有 RV32_BASE、没有 AXI），所以 Host 编译就是它的全部覆盖 ——
 * 和别的 PS 程序不一样，那些必须上板才有意义。
 *
 * 输出一律 ASCII：板子串口按 cp936 解码，xil_printf 打中文必乱码（见 ps_main.c 头注）。
 * 也**不用宽度修饰符**（%2d / %-6s）—— xil_printf 没有它们，打出来是垃圾。
 *
 * ⚠ 不一致时的排查顺序（照这个来，别乱猜，也别先怀疑算法）：
 *     1. clf_cut_feat / clf_node_class 的 **1 起 vs 0 起** —— 最可能
 *     2. 导出时阈值被 float 截断（样本正好压在阈值上）   —— 其次
 *     3. 推理逻辑本身                                  —— 最不可能
 *   这三条的顺序不是随意的：第 1 条最可能，第 3 条最不可能。
 */
#include "xil_printf.h"
#include "ps_classifier.h"

static int failures;

int main(void)
{
    int i, c, ok = 0, got;
    int votes[CLF_N_CLASS];

    xil_printf("\r\n===== station 12: random forest inference self-test =====\r\n");
    xil_printf("trees %d  nodes %d  feat %d  class %d\r\n",
               CLF_N_TREE, CLF_N_NODE, CLF_N_FEAT, CLF_N_CLASS);

    for (i = 0; i < CLF_N_TEST; i++) {
        got = clf_predict(&clf_test_x[i * CLF_N_FEAT], votes);

        xil_printf("case %d  want %s  got %s  votes",
                   i, clf_class_names[clf_test_y[i] - 1], clf_class_names[got - 1]);
        for (c = 0; c < CLF_N_CLASS; c++) {
            xil_printf(" %d", votes[c]);
        }
        if (got == clf_test_y[i]) {
            xil_printf("  ok\r\n");
            ok++;
        } else {
            xil_printf("  FAIL\r\n");
            failures++;
        }
    }

    xil_printf("%d/%d match MATLAB\r\n", ok, CLF_N_TEST);
    xil_printf("CLF_RESULT_%s (%d failures)\r\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures;
}
