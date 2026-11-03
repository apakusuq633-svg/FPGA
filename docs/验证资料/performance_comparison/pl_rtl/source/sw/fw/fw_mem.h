/* Production DTCM address map; must match sw/fw/link.ld.
 * Data/BSS: 0x0000..0x27ff; results: 0x2800..0x287f;
 * FFT output: 0x2880..0x30bf; GCC output: 0x30c0..0x38bf;
 * FIR results: 0x38c0..0x38df; steering: 0x3c60..0x3c7f;
 * stack: 0x3c80..0x3fef, top 0x3ff0.
 * The gap above FIR remains reserved for archived comparison compatibility.
 */
#ifndef FW_MEM_H
#define FW_MEM_H
#include <stdint.h>
#ifdef FW_MEM_RELOCATE
extern uint8_t *fw_mem_scratch;
#define FW_RES_BASE ((uint32_t)(uintptr_t)(fw_mem_scratch + 0x000u))
#define FW_OUT_BASE ((uint32_t)(uintptr_t)(fw_mem_scratch + 0x080u))
#define FW_OUT2_BASE ((uint32_t)(uintptr_t)(fw_mem_scratch + 0x8C0u))
#define FW_AUDIO_BASE ((uint32_t)(uintptr_t)(fw_mem_scratch + 0x10C0u))
#define FW_STEER_BASE ((uint32_t)(uintptr_t)(fw_mem_scratch + 0x1460u))
#else
#ifndef FW_RES_BASE
#define FW_RES_BASE 0x2800u
#endif
#ifndef FW_OUT_BASE
#define FW_OUT_BASE 0x2880u
#endif
#ifndef FW_OUT2_BASE
#define FW_OUT2_BASE 0x30C0u
#endif
#define FW_AUDIO_BASE 0x38C0u
#define FW_STEER_BASE 0x3C60u
#endif
#define AUDIO(i) (*(volatile uint32_t *)(FW_AUDIO_BASE + 4u * (uint32_t)(i)))
/* Archived GSC sources are not linked into either production image. */
#define FW_GSC_BASE FW_AUDIO_BASE
#define FW_GSC_EXTRA (FW_GSC_BASE + 0x380u)
#endif
