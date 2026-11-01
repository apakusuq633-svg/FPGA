#ifndef FW_CYCLE_PROFILE_H
#define FW_CYCLE_PROFILE_H
#ifndef FW_MEM_PROFILE
#define FW_MEM_PROFILE 0
#endif
#if FW_MEM_PROFILE
#define MEM_PHASE(n) (*(volatile uint32_t *)0x2bc0u=(n))
#else
#define MEM_PHASE(n) ((void)0)
#endif
#include <stdint.h>
#ifndef FW_CYCLE_PROFILE
#define FW_CYCLE_PROFILE 0
#endif
#ifndef FW_DETAIL_PROFILE
#define FW_DETAIL_PROFILE 0
#endif
#if FW_DETAIL_PROFILE
extern uint32_t fw_capture_detail[4],fw_prepare_detail[5];
#endif
static inline uint32_t read_cycles(void)
{
    uint32_t value;
    __asm__ volatile("rdcycle %0" : "=r"(value) : : "memory");
    return value;
}
#if FW_DETAIL_PROFILE
/* Force register-only arithmetic to finish before its timestamp as well. */
static inline uint32_t read_cycles_after2(uint32_t a,uint32_t b)
{
    uint32_t value;
    __asm__ volatile("rdcycle %0":"=r"(value):"r"(a),"r"(b):"memory");
    return value;
}
static inline uint32_t read_cycles_after_stats(int32_t s0,int32_t s1,uint64_t e0,uint64_t e1,
                                               uint32_t p0,uint32_t p1,uint32_t c0,uint32_t c1)
{
    uint32_t value;
    __asm__ volatile("rdcycle %0":"=r"(value):"r"(s0),"r"(s1),"r"((uint32_t)e0),"r"((uint32_t)(e0>>32)),
        "r"((uint32_t)e1),"r"((uint32_t)(e1>>32)),"r"(p0),"r"(p1),"r"(c0),"r"(c1):"memory");
    return value;
}
#endif
#if FW_CYCLE_PROFILE
extern uint32_t fw_fft_profile[3];
extern uint32_t fw_ifft_profile[3];
extern uint32_t fw_gcc_profile[5];
#endif
#endif
