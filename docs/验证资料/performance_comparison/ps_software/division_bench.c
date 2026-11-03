/* The accelerated path calls the unchanged production exact division helper. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include "gsc9.c"
#define EXPORT __declspec(dllexport)
#define BATCHES 4096u
static uint64_t denominators[BATCHES];
static int64_t numerators[BATCHES][32],quotients[BATCHES][32];
static int read_exact(const char *path,void *dst,size_t bytes){
 FILE *f=fopen(path,"rb");if(!f)return 0;
 int ok=fread(dst,1,bytes,f)==bytes&&fgetc(f)==EOF;fclose(f);return ok;
}
EXPORT int bench_division_load(const char *ns,const char *ds){
 if(!read_exact(ns,numerators,sizeof(numerators))||!read_exact(ds,denominators,sizeof(denominators)))return 0;
 for(unsigned b=0;b<BATCHES;b++)if(!denominators[b]||denominators[b]>(UINT64_C(1)<<35)+(UINT64_C(1)<<30))return 0;
 return 1;
}
static __attribute__((noinline)) void baseline(void){
 for(unsigned b=0;b<BATCHES;b++)for(unsigned j=0;j<32;j++)
  quotients[b][j]=numerators[b][j]/(int64_t)denominators[b];
}
static __attribute__((noinline)) void shared(void){
 for(unsigned b=0;b<BATCHES;b++){
  uint64_t d=denominators[b],r=(UINT64_C(1)<<63)/d;
  for(unsigned j=0;j<32;j++)quotients[b][j]=divide_shared(numerators[b][j],d,r);
 }
}
EXPORT int bench_division_once(int mode,double *milliseconds){
 LARGE_INTEGER a,b,f;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&a);
 if(mode==0)baseline();else if(mode==1)shared();else return 0;
 QueryPerformanceCounter(&b);*milliseconds=1000.0*(double)(b.QuadPart-a.QuadPart)/(double)f.QuadPart;return 1;
}
EXPORT int bench_division_dump(const char *path){
 FILE *f=fopen(path,"wb");if(!f)return 0;
 int ok=fwrite(quotients,1,sizeof(quotients),f)==sizeof(quotients);fclose(f);return ok;
}
