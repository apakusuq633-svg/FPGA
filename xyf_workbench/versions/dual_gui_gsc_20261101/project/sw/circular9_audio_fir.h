/* Bit-exact audio-only FIR; mirror ring removes per-tap circular indexing.
 * ARMv7 DSP instructions use integer core, no VFP/NEON context changes. */
#ifndef CIRCULAR9_AUDIO_FIR_H
#define CIRCULAR9_AUDIO_FIR_H
#include <stdint.h>
#include <string.h>
static int32_t c9_audio_fir127(const int16_t ring[256],unsigned head,const int16_t coeff[127]){
 int64_t acc=0;
 /* Symmetric taps let ascending samples use ascending coefficients.
  * First 126 values cover ages126..1; final tap covers age0. */
 const int16_t *x=ring+head+2;
 for(unsigned j=0;j<126;j+=2){
#if defined(__arm__) && defined(__ARM_ARCH) && __ARM_ARCH >= 7 && !defined(C9_FIR_PORTABLE)
  uint32_t a,b;memcpy(&a,x+j,4);memcpy(&b,coeff+j,4);
  __asm__("smlald %Q0, %R0, %1, %2" : "+r"(acc) : "r"(a),"r"(b));
#else
  acc+=(int32_t)x[j]*coeff[j];acc+=(int32_t)x[j+1]*coeff[j+1];
#endif
 }
 acc+=(int32_t)x[126]*coeff[126];return (int32_t)acc;
}
#endif
