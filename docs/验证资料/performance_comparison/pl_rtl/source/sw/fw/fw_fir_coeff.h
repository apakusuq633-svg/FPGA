#ifndef FW_FIR_COEFF_H
#define FW_FIR_COEFF_H
#include <stdint.h>
#define FW_FIR_TAPS 32
static const int16_t fw_fir_coeff[32] = {
-11, -63, 25, 129, -70, -273, 173, 517, -378, -903, 771, 1557, -1613, -3034, 4541, 15016, 15016, 4541, -3034, -1613, 1557, 771, -903, -378, 517, 173, -273, -70, 129, 25, -63, -11
};
#endif
