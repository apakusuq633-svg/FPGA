#include <windows.h>
#include <stdio.h>
#include "circular9_envelope.h"
#define EXPORT __declspec(dllexport)
static double input[40000],last_features[2][18],shaft;
static c9_diag_extraction metadata;
void bench_legacy_envelope(const double*,double,double[18]);
EXPORT int bench_envelope_load(const char *path,double hz){
 FILE *f=fopen(path,"rb");if(!f)return 0;
 int ok=fread(input,sizeof(double),40000,f)==40000&&fgetc(f)==EOF;fclose(f);shaft=hz;return ok;
}
EXPORT int bench_envelope_once(int mode,double *milliseconds){
 LARGE_INTEGER a,b,f;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&a);int ok=1;
 if(mode==0)bench_legacy_envelope(input,shaft,last_features[0]);
 else if(mode==1)ok=c9_env_extract(input,shaft,last_features[1],&metadata);else return 0;
 QueryPerformanceCounter(&b);*milliseconds=1000.0*(double)(b.QuadPart-a.QuadPart)/(double)f.QuadPart;return ok;
}
EXPORT void bench_envelope_features(int mode,double *out){memcpy(out,last_features[mode],18*sizeof(double));}
EXPORT void bench_envelope_spectrum(double *out){memcpy(out,c9_env_spectrum,sizeof(c9_env_spectrum));}
EXPORT unsigned bench_envelope_status(void){return metadata.status;}
