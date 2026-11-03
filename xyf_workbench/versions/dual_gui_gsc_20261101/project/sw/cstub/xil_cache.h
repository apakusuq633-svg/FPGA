/* Compile-only public cache API. Keep separate from xil_cache_l.h, like the BSP,
 * so the check catches a missing public API include. Never link or run these stubs. */
#ifndef XIL_CACHE_H
#define XIL_CACHE_H
#include "xil_types.h"
static inline void Xil_DCacheInvalidate(void) {}
static inline void Xil_DCacheInvalidateRange(INTPTR adr, u32 len) { (void)adr; (void)len; }
static inline void Xil_DCacheFlush(void) {}
static inline void Xil_DCacheFlushRange(INTPTR adr, u32 len) { (void)adr; (void)len; }
#endif
