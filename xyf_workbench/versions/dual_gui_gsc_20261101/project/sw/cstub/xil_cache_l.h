/* See the comment at the top of sw/cstub/xil_io.h for what this directory is.
 *
 * The cache maintenance calls the PS-side programs make. Names match the BSP's
 * xil_cache_l.h / xil_cache.h so the sources compile unchanged; the bodies do nothing,
 * because this directory is compile-only (see xil_io.h). */
#ifndef XIL_CACHE_L_H
#define XIL_CACHE_L_H

#include "xil_types.h"

static inline void Xil_L1DCacheInvalidate(void) {}
static inline void Xil_L1ICacheInvalidate(void) {}
static inline void Xil_L2CacheInvalidate(void) {}

#endif
