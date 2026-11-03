#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
static uint64_t ticks(void){LARGE_INTEGER n;QueryPerformanceCounter(&n);return (uint64_t)n.QuadPart;}
static uint64_t frequency(void){LARGE_INTEGER n;QueryPerformanceFrequency(&n);return (uint64_t)n.QuadPart;}
#else
#include <time.h>
static uint64_t ticks(void){struct timespec n;clock_gettime(CLOCK_MONOTONIC,&n);return (uint64_t)n.tv_sec*1000000000u+n.tv_nsec;}
static uint64_t frequency(void){return 1000000000u;}
#endif
#include "c9_scalar.h"
#include "hann_q14.h"
static int16_t raw[1024*9],correlation[36*64];
static uint8_t lut[C9S_LUT_BYTES];
static c9s_workspace work;
static int32_t scores[1024];
static int load(const char *path,void *target,size_t bytes){FILE *f=fopen(path,"rb");if(!f)return 0;size_t n=fread(target,1,bytes,f);int extra=fgetc(f);fclose(f);return n==bytes&&extra==EOF;}
static int dump(const char *dir,const char *name,const void *source,size_t bytes){char p[2048];snprintf(p,sizeof(p),"%s/%s",dir,name);FILE *f=fopen(p,"wb");if(!f)return 0;int ok=fwrite(source,1,bytes,f)==bytes;fclose(f);return ok;}
int main(int argc,char **argv){
 if(argc<4||argc>5)return 2;
 if(!load(argv[1],raw,sizeof(raw))||!load(argv[2],lut,sizeof(lut)))return 3;
 unsigned repeat=argc==5?(unsigned)strtoul(argv[4],0,10):0;
 c9s_locate(raw,lut,c9s_hann,&work,correlation,scores);
 if(!dump(argv[3],"statistics.bin",work.statistics,sizeof(work.statistics))||!dump(argv[3],"spectrum.bin",work.spectrum,sizeof(work.spectrum))||!dump(argv[3],"correlation.bin",correlation,sizeof(correlation))||!dump(argv[3],"scores.bin",scores,sizeof(scores)))return 4;
 unsigned best=0;for(unsigned i=1;i<1024;i++)if(scores[i]>scores[best])best=i;
 printf("C9_SCALAR_OUTPUT best_grid=%u score=%d channels=9 pairs=36 grid=1024 workspace_bytes=%u\n",best,scores[best],(unsigned)sizeof(work));
 if(repeat){
  const unsigned rounds=9;uint64_t values[9];volatile uint32_t checksum=0;
  for(unsigned warm=0;warm<3;warm++)c9s_locate(raw,lut,c9s_hann,&work,correlation,scores);
  for(unsigned round=0;round<rounds;round++){
   uint64_t start=ticks();for(unsigned i=0;i<repeat;i++){c9s_locate(raw,lut,c9s_hann,&work,correlation,scores);checksum^=(uint32_t)scores[(round+i)&1023];}
   values[round]=ticks()-start;
   printf("C9_SCALAR_HOST round=%u repeat=%u ticks=%llu frequency=%llu\n",round,repeat,(unsigned long long)values[round],(unsigned long long)frequency());
  }
  printf("C9_SCALAR_CHECKSUM %u\n",(unsigned)checksum);
 }
 return 0;
}
