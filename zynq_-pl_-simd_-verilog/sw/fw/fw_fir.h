#ifndef FW_FIR_H
#define FW_FIR_H
#include <stdint.h>
#include "fw_fir_coeff.h"
#define FW_FIR_SAMPLES 512
void fw_fir_run(int accelerated);
#endif
