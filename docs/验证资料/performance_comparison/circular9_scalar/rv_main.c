#include <stdint.h>
#include "c9_scalar.h"
#include "hann_q14.h"
static c9s_workspace workspace;
#ifdef C9S_PROFILE
extern volatile uint32_t c9s_phase_cycles[4];
#endif
static uint32_t cycles(void){uint32_t n;__asm__ volatile("rdcycle %0\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop":"=r"(n)::"memory");return n;}
int main(void){
 volatile uint32_t *mail=(volatile uint32_t *)0x3800;
 const uint8_t *lut=(const uint8_t *)0x10000;
 const int16_t *raw=(const int16_t *)(0x10000+C9S_LUT_BYTES);
 int16_t *correlations=(int16_t *)(0x10000+C9S_LUT_BYTES);
 int32_t *scores=(int32_t *)(0x10000+C9S_LUT_BYTES+36*64*2);
 mail[0]=0x53544152; /* raw/LUT already loaded by the isolated TB */
 uint32_t start=cycles();
 c9s_locate(raw,lut,c9s_hann,&workspace,correlations,scores);
 uint32_t elapsed=cycles()-start;
 mail[1]=elapsed;mail[2]=(uint32_t)(uintptr_t)&workspace;
 unsigned best=0;for(unsigned i=1;i<1024;i++)if(scores[i]>scores[best])best=i;
 mail[3]=best;mail[4]=(uint32_t)scores[best];mail[5]=sizeof(workspace);
#ifdef C9S_PROFILE
 for(unsigned i=0;i<4;i++)mail[6+i]=c9s_phase_cycles[i];
#else
 for(unsigned i=0;i<4;i++)mail[6+i]=0;
#endif
 mail[0]=0x43395343;
 *(volatile uint32_t *)0x4000=0x43395343;
 for(;;){}
}
