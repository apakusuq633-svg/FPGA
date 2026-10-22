/* 自动生成，不要手改 —— 源在 scripts/golden/fw_fft_model.py。
 *
 * 1024 点实数 FFT 的旋转因子 W_1024^k = e^{-j2πk/1024}，k = 0..512，
 * 复数按 re/im 分开存，各 int16 **Q14**。
 *
 * Q14 不是随便挑的：Q15 装不下 1.0（W^0 = 16'h8000 会被当成 -1.0，
 * 等于把信号反相）。同一个坑见 docs/issues/029。
 *
 * 这里只有**声明**，定义在 fw_tables.c —— 见那个文件头部。
 */
#ifndef FW_TABLES_H
#define FW_TABLES_H

#include <stdint.h>

#define FW_TW_N     513   /* k = 0..512 */
#define FW_TW_FRAC  14

extern const int16_t g_tw_re[FW_TW_N];
extern const int16_t g_tw_im[FW_TW_N];

#endif /* FW_TABLES_H */
