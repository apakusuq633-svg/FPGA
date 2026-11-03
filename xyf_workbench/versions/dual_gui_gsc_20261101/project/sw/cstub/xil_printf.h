/* See the comment at the top of sw/cstub/xil_io.h for what this directory is. */
#ifndef XIL_PRINTF_H
#define XIL_PRINTF_H
/* Match the BSP's void return type, and let GCC check argument types/counts.
 * This checks standard printf types, not every restriction of xil_printf. */
void xil_printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#endif
