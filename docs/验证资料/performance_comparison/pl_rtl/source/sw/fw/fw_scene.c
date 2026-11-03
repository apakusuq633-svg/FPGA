/* 场景/源信号/定点插值 —— 定义（声明在 fw_scene.h）。
 *
 * ⚠⚠ **这些必须是 extern，不能写成 `static inline` 放头文件里。**
 *   踩过：DAS 与 GSC 都要用它们，抽成公共头之后每个 .c 各生成一份
 *   ⇒ `.text` 从 0x1b4c 涨到 0x212c，**冲破了 0x2000 的代码上限**。
 *   先用 -Os 硬塞回去，结果**运行时间涨了 2.9×**（DAS 548,305 → 1,586,974 拍）——
 *   对一个"拍数就是产品指标"的工程，这个代价远大于多几十字节的调用开销。
 *   正确做法就是这里：一份定义 + 头里声明。
 *
 * 定点口径的**唯一出处**是 scripts/golden/fw_das_model.py。
 */
#include "fw_scene.h"

uint32_t mix32(uint32_t x)
{
    x ^= x >> 16;
    x *= MIX_A;
    x ^= x >> 15;
    x *= MIX_B;
    x ^= x >> 16;
    return x;
}

int32_t scaled_src(uint32_t seed, int32_t k, int32_t amp)
{
    if (k < 0) { return 0; }
    int32_t v = (int32_t)((mix32(seed ^ (uint32_t)k) >> 16) & 0xFFFFu) - 32768;
    return (v * amp) >> 15;
}

int32_t interp_src(uint32_t D, int32_t n, uint32_t seed, int32_t amp)
{
    int32_t  idx = (int32_t)(D >> 16);
    uint32_t fr4 = (D >> 12) & 0xFu;
    int32_t  v0  = scaled_src(seed, n - idx,     amp);
    int32_t  v1  = scaled_src(seed, n - idx - 1, amp);
    return v0 + (((v1 - v0) * (int32_t)fr4) >> 4);
}

int32_t interp_noise(uint32_t D, int32_t n, int m)
{
    return interp_src(D, n, SEED_NOISE0 + (uint32_t)m, AMP_NSE);
}
