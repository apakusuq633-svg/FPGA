/* Host-only wrapper: production source is included unchanged. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include "circular9_candidates.c"
#define EXPORT __declspec(dllexport)
static int16_t bench_raw[C9_SEARCH_RAW_FRAMES][9];
static uint32_t bench_lut[9*1024];
static c9_separation_workspace bench_workspace;
static c9_search_feedback bench_feedback;
static c9_search_context bench_context;
static int read_exact(const char *path,void *dst,size_t bytes){
 FILE *f=fopen(path,"rb");if(!f)return 0;
 int ok=fread(dst,1,bytes,f)==bytes&&fgetc(f)==EOF;fclose(f);return ok;
}
static int write_exact(const char *path,const void *src,size_t bytes){
 FILE *f=fopen(path,"wb");if(!f)return 0;
 int ok=fwrite(src,1,bytes,f)==bytes;fclose(f);return ok;
}
EXPORT int bench_search_load(const char *pcm,const char *lut,uint32_t geometry,uint32_t calibration){
 if(!read_exact(pcm,bench_raw,sizeof(bench_raw))||!read_exact(lut,bench_lut,sizeof(bench_lut)))return 0;
 bench_context=(c9_search_context){.session=7,.epoch=3,.first_sample=80000,
  .end_sample=80000+C9_SEARCH_RAW_FRAMES,.geometry_version=geometry,
  .calibration_version=calibration,.geometry_confirmed=0};
 return 1;
}
EXPORT int bench_search_once(double *milliseconds){
 LARGE_INTEGER a,b,f;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&a);
 int rc=c9_candidates_search(bench_raw,C9_SEARCH_RAW_FRAMES,bench_lut,&bench_workspace,&bench_context,&bench_feedback);
 QueryPerformanceCounter(&b);*milliseconds=1000.0*(double)(b.QuadPart-a.QuadPart)/(double)f.QuadPart;return rc;
}
EXPORT int bench_search_dump(const char *feedback,const char *scores,const char *lags){
 return write_exact(feedback,&bench_feedback,sizeof(bench_feedback))&&
  write_exact(scores,bench_workspace.search_scores,sizeof(bench_workspace.search_scores))&&
  write_exact(lags,bench_workspace.search_lags,sizeof(bench_workspace.search_lags));
}
EXPORT unsigned bench_search_feedback_bytes(void){return sizeof(bench_feedback);}
