/* Isolated measurement driver. Original production kernels remain unmodified. */
#include <stdint.h>
#include "fw_fft.h"
#include "fw_fir.h"
#include "fw_mem.h"
#include "fw_cycle_profile.h"
#define RES ((volatile uint32_t *)0x2800u)
#define INPUT ((int16_t *)0x10000u)
#define SCALAR ((volatile int16_t *)0x10800u)
#define HARDWARE ((volatile int16_t *)0x11100u)
int main(void) {
  for (unsigned n=0;n<64;n++) RES[n]=0;
  for (unsigned n=0;n<1024;n++) {
    uint32_t v=(n+1u)*1103515245u+12345u;
    INPUT[n]=(int16_t)((int32_t)((v>>16)&65535u)-32768);
  }
  fft_init();
  uint32_t t=read_cycles(); fft1024(INPUT,SCALAR); RES[1]=read_cycles()-t;
  t=read_cycles(); fft1024_hw(INPUT,HARDWARE); RES[2]=read_cycles()-t;
  RES[3]=fw_fft_profile[0]; RES[4]=fw_fft_profile[1]; RES[5]=fw_fft_profile[2];
  for(unsigned n=0;n<1026;n++) if(SCALAR[n]!=HARDWARE[n]) RES[6]++;
  /* Actual fw_fir_run is timed without per-sample instrumentation. */
  t=read_cycles(); fw_fir_run(0); RES[7]=read_cycles()-t;
  t=read_cycles(); fw_fir_run(1); RES[8]=read_cycles()-t;
  RES[9]=AUDIO(0);RES[10]=AUDIO(1);RES[11]=AUDIO(2);RES[12]=AUDIO(3);
  /* Per-sample FIR outputs are observed at retirement by the testbench. */
  RES[14]=1026;RES[15]=512;
  __asm__ volatile("" ::: "memory");
  RES[0]=0x50455246u;
  for(;;) __asm__ volatile("nop");
}
