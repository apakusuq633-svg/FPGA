/* See the comment at the top of sw/cstub/xil_io.h for what this directory is.
 *
 * Only Xil_SetTlbAttributes and the NORM_* page attributes are used by the PS-side
 * programs (ps_dualcore.c / ps_fft_test.c map the OCM share page as non-cacheable with it).
 *
 * !! The NORM_* values below are PLACEHOLDERS (0), not the real ARMv7 section
 * descriptors. !! The genuine ones live in the BSP's xil_mmu.h. They are not reproduced
 * here for the same reason as the other placeholders in this directory: a plausible-looking
 * constant sitting in the tree looks authoritative and gets copied. Nothing is lost -- this
 * directory is compile-only, so the value never reaches hardware. */
#ifndef XIL_MMU_H
#define XIL_MMU_H

#include "xil_types.h"

#define NORM_NONCACHE  0u
#define NORM_WB_CACHE  0u
#define DEVICE_MEMORY  0u

static inline void Xil_SetTlbAttributes(INTPTR Addr, u32 attrib)
{
    (void)Addr;
    (void)attrib;
}

#endif
