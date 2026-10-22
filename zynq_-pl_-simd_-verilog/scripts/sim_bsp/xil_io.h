#ifndef ACOUSTIC_SIM_XIL_IO_H
#define ACOUSTIC_SIM_XIL_IO_H
#include <stdint.h>
void Xil_Out32(uint32_t address, uint32_t value);
uint32_t Xil_In32(uint32_t address);
#endif
