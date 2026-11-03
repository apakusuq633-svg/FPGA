/* Host fixture driver. No training labels or physical accuracy claims. */
#include "circular9_envelope.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double audio[C9_DIAG_SAMPLES];
extern void c9_legacy_benchmark(const double *x,double hz,double v[18]);
int main(int argc,char **argv) {
 if(argc!=3)return 2;
 FILE *f=fopen(argv[1],"rb");
 if(!f || fread(audio,sizeof(double),C9_DIAG_SAMPLES,f)!=C9_DIAG_SAMPLES)return 3;
 fclose(f);double v[18],hz=strtod(argv[2],0);c9_diag_extraction m;
 if(!c9_env_extract(audio,hz,v,&m))return 4;
 printf("{\"status\":%u,\"samples\":%u,\"fft_size\":%u,\"fft_count\":%u,"
  "\"fir_multiplications\":%u,\"observation_seconds\":%.17g,"
  "\"bin_spacing_hz\":%.17g,\"enbw_hz\":%.17g,\"first_null_hz\":%.17g,"
  "\"carrier_rms\":%.17g,\"modulation_rms\":%.17g,\"features\":[",
  m.status,m.envelope_samples,m.fft_size,m.fft_count,m.fir_multiplications,
  m.observation_seconds,m.bin_spacing_hz,m.hann_enbw_hz,m.hann_first_null_hz,
  m.carrier_rms,m.modulation_rms);
 for(unsigned i=0;i<18;i++)printf("%s%.17g",i?",":"",v[i]);
 printf("],\"spectrum\":[");
 for(unsigned i=0;i<C9_ENV_BINS;i++)printf("%s%.17g",i?",":"",c9_env_spectrum[i]);
 /* Same process, compiler, audio and warmed initialization; native timing only. */
 c9_legacy_benchmark(audio,hz,v);
 clock_t start=clock();
 for(unsigned i=0;i<32;i++)c9_env_extract(audio,hz,v,&m);
 double new_ms=1000.0*(clock()-start)/(32.0*CLOCKS_PER_SEC);
 start=clock();for(unsigned i=0;i<32;i++)c9_legacy_benchmark(audio,hz,v);
 double old_ms=1000.0*(clock()-start)/(32.0*CLOCKS_PER_SEC);
 printf("],\"host_new_ms\":%.6f,\"host_legacy_ms\":%.6f}\n",new_ms,old_ms);
 return 0;
}
