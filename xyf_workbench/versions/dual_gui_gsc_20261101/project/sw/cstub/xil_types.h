/* See the comment at the top of sw/cstub/xil_io.h for what this directory is.
 *
 * Just the handful of Xilinx typedefs the BSP headers use in their prototypes. The real
 * file is generated/shipped with the BSP; this exists so declarations like
 * `Xil_SetTlbAttributes(INTPTR Addr, u32 attrib)` parse on the host. */
#ifndef XIL_TYPES_H
#define XIL_TYPES_H

#include <stdint.h>

typedef int8_t   s8;
typedef uint8_t  u8;
typedef int16_t  s16;
typedef uint16_t u16;
typedef int32_t  s32;
typedef uint32_t u32;
typedef int64_t  s64;
typedef uint64_t u64;

typedef intptr_t  INTPTR;
typedef uintptr_t UINTPTR;

#endif
