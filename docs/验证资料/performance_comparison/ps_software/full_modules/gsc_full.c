/* Full production gsc9_process, not just its normalization arithmetic. */
#include <windows.h>
#include <stdio.h>
#include "gsc9.c"
#define EXPORT __declspec(dllexport)
#define PREFIX 512u
#define BODY 32768u
static uint32_t packets[PREFIX+BODY][16];
static int16_t output[BODY];
static gsc9_state state;
static gsc9_config config;
static int read_file(const char *path,void *p,size_t bytes){
 FILE *f=fopen(path,"rb");if(!f)return 0;int ok=fread(p,1,bytes,f)==bytes&&fgetc(f)==EOF;fclose(f);return ok;
}
EXPORT int full_gsc_load(const char *packet_path,const char *fir_path){
 zero(&config,sizeof(config));config.version=1;config.direction_id=7;config.mu_q15=8192;config.epsilon=1u<<20;
 return read_file(packet_path,packets,sizeof(packets))&&read_file(fir_path,config.fir_q15,sizeof(config.fir_q15));
}
EXPORT int full_gsc_once(int mode,double *ms){
 gsc9_reset(&state);if(gsc9_configure(&state,&config))return 0;
 gsc9_set_target_guard(&state,1);
 int enabled=mode!=0,freeze=mode==2;
 for(unsigned n=0;n<PREFIX;n++)gsc9_process(&state,packets[n],enabled,freeze);
 LARGE_INTEGER f,a,b;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&a);
 for(unsigned n=0;n<BODY;n++)output[n]=gsc9_process(&state,packets[n+PREFIX],enabled,freeze);
 QueryPerformanceCounter(&b);*ms=1000.0*(b.QuadPart-a.QuadPart)/f.QuadPart;return 1;
}
EXPORT int full_gsc_dump(const char *path){
 FILE *f=fopen(path,"wb");if(!f)return 0;int ok=fwrite(output,1,sizeof(output),f)==sizeof(output);fclose(f);return ok;
}
EXPORT uint64_t full_gsc_stat(unsigned n){return gsc9_stat(&state,n);}
EXPORT unsigned full_gsc_reason(void){return gsc9_reason(&state);}
EXPORT void full_gsc_weights(int32_t *out){gsc9_get_weights(&state,out);}
