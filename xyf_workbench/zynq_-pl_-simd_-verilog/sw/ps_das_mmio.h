/* Adapter for a matching PL bitstream only. Unmapped AXI reads may abort on ARM. */
#ifndef PS_DAS_MMIO_H
#define PS_DAS_MMIO_H
#include "xil_io.h"
#include "ps_das_audio.h"
static inline uint32_t das_mmio_read(void *ctx, uint32_t offset)
{ return Xil_In32((uintptr_t)ctx+offset); }
static inline void das_mmio_write(void *ctx, uint32_t offset, uint32_t value)
{ Xil_Out32((uintptr_t)ctx+offset,value); }
static inline das_bus das_mmio_bus(uintptr_t rv32_base)
{
    das_bus b;
    b.ctx=(void *)(rv32_base+DAS_AUDIO_WINDOW);
    b.read=das_mmio_read;b.write=das_mmio_write;
    return b;
}
static inline das_bus das_axi_bus(uintptr_t rv32_base)
{
    das_bus b;
    b.ctx=(void *)rv32_base;b.read=das_mmio_read;b.write=das_mmio_write;
    return b;
}
#endif
