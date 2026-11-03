#include "fw_fir.h"
#include "fw_mem.h"
#include "fw_scene.h"
#include "fw_plat.h"

void fw_fir_run(int accelerated)
{
    volatile int16_t history[FW_FIR_TAPS];
    for (int k = 0; k < FW_FIR_TAPS; ++k) history[k] = 0;
    uint32_t ck = 0, wck = 0;
    int pos = 0;
    for (int n = 0; n < FW_FIR_SAMPLES; ++n) {
        uint32_t v = (uint32_t)(n + 1) * 1103515245u + 12345u;
        int32_t x = (int32_t)((v >> 16) & 65535u) - 32768;
        int32_t y;
#if FW_HAVE_HW
        if (accelerated) {
            int32_t dot;
            __asm__ volatile(".insn r 0x0B, 0, 0, x0, %0, x0" :: "r"(x));
            /* rs2's register number encodes passes minus one (32/8 - 1). */
            __asm__ volatile(".insn r 0x0B, 1, 0, %0, x0, x3" : "=r"(dot));
            y = dot >> 15;
        } else
#endif
        {
            int32_t dot = 0;
            history[pos] = (int16_t)x;
            for (int k = 0; k < FW_FIR_TAPS; ++k)
                dot += (int32_t)fw_fir_coeff[k] * history[(pos - k) & (FW_FIR_TAPS - 1)];
            pos = (pos + 1) & (FW_FIR_TAPS - 1);
            y = dot >> 15;
        }
        if (y > 32767) y = 32767;
        if (y < -32768) y = -32768;
        ck += (uint32_t)y;
        wck += (uint32_t)(y * (n + 1));
    }
    AUDIO(accelerated ? 2 : 0) = ck;
    AUDIO(accelerated ? 3 : 1) = wck;
}
