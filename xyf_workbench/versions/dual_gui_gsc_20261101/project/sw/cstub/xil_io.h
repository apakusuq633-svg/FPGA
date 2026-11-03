/* ===========================================================================
 * sw/cstub/ -- stand-ins for the Vitis BSP headers, for host-side compilation only.
 *
 * verify.ps1 item 14 runs scripts/check_ps_apps.py with these headers so C errors
 * in the PS-side sources are caught before the Vitis/board step:
 *
 *     gcc -fsyntax-only -I sw/cstub -I sw ...
 *
 * to prove the PS-side C still parses, type-checks and passes -Wall -Wextra -Werror.
 * That is cheap and catches the majority of real edits.
 *
 * What this is NOT: a hardware model. Xil_In32 returns 0, so every [ok]/[FAIL]
 * judgement would fail if the program were actually run against these -- deliberately,
 * because a fake register file would be "testing the software against fake hardware".
 * So: compile only, never run.
 *
 * These are never used in a Vitis build -- Vitis picks up its own generated BSP
 * headers. Keep them out of any -I that Vitis sees.
 * ======================================================================== */
#ifndef XIL_IO_H
#define XIL_IO_H
#include <stdint.h>
#include <stddef.h>     /* NULL; the real BSP headers provide it too */
static inline void     Xil_Out32(uint32_t a, uint32_t v) { (void)a; (void)v; }
static inline uint32_t Xil_In32 (uint32_t a)             { (void)a; return 0u; }
#endif
