#include <windows.h>
#include <math.h>
#include <stdio.h>
#include "circular9_candidates.c"
#define EXPORT __declspec(dllexport)
#define TONES 40u
static int16_t raw[C9_SNAPSHOT_FRAMES][9];
static uint32_t lut[9*1024];
static c9_candidate cand[2]={{.grid=16*32+3,.score=1000},{.grid=16*32+28,.score=900}};
static c9_separation_workspace workspace;
static c9_separation_report report;
static double output[C9_CANDIDATES][C9_AUDIO_FRAMES];
static int read_file(const char *path,void *p,size_t bytes){
 FILE *f=fopen(path,"rb");if(!f)return 0;int ok=fread(p,1,bytes,f)==bytes&&fgetc(f)==EOF;fclose(f);return ok;
}
static int write_file(const char *path,const void *p,size_t bytes){
 FILE *f=fopen(path,"wb");if(!f)return 0;int ok=fwrite(p,1,bytes,f)==bytes;fclose(f);return ok;
}
EXPORT int full_sep_generate(const char *lut_path,const char *pcm_path){
 if(!read_file(lut_path,lut,sizeof(lut)))return 0;
 static double osc[2][9][TONES][2],rotation[2][TONES][2];
 uint32_t random_state=20261028;
 const double two_pi=6.2831853071795864769,amplitude[2]={.04,.03};
 for(unsigned s=0;s<2;s++)for(unsigned t=0;t<TONES;t++){
  double hz=2200+125*t+33*s,step=two_pi*hz/156250.;
  rotation[s][t][0]=cos(step);rotation[s][t][1]=sin(step);
  random_state=random_state*1664525u+1013904223u;double phase=two_pi*random_state/4294967296.;
  for(unsigned ch=0;ch<9;ch++){
   int q=lut[ch*1024+cand[s].grid]&16383u;if(q&8192)q-=16384;
   double p=phase+two_pi*hz*q/(16.*156250.);
   osc[s][ch][t][0]=cos(p);osc[s][ch][t][1]=sin(p);
  }
 }
 for(unsigned n=0;n<C9_SNAPSHOT_FRAMES;n++)for(unsigned ch=0;ch<9;ch++){
  double value=0;
  for(unsigned s=0;s<2;s++)for(unsigned t=0;t<TONES;t++){
   double a=osc[s][ch][t][0],b=osc[s][ch][t][1];value+=amplitude[s]*b/sqrt(TONES/2.);
   osc[s][ch][t][0]=a*rotation[s][t][0]-b*rotation[s][t][1];
   osc[s][ch][t][1]=b*rotation[s][t][0]+a*rotation[s][t][1];
  }
  long v=lround(value*32768.);if(v>=32767||v<=-32768)return 0;raw[n][ch]=(int16_t)v;
 }
 return write_file(pcm_path,raw,sizeof(raw));
}
EXPORT int full_sep_load(const char *lut_path,const char *pcm_path){return read_file(lut_path,lut,sizeof(lut))&&read_file(pcm_path,raw,sizeof(raw));}
EXPORT int full_sep_once(double *ms){
 LARGE_INTEGER f,a,b;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&a);
 int rc=c9_candidates_separate(raw,cand,2,lut,&workspace,output,&report);
 QueryPerformanceCounter(&b);*ms=1000.0*(b.QuadPart-a.QuadPart)/f.QuadPart;return rc;
}
EXPORT int full_sep_dump(const char *audio,const char *metadata){return write_file(audio,output,sizeof(output))&&write_file(metadata,&report,sizeof(report));}
EXPORT unsigned full_sep_metric(unsigned n){
 const unsigned v[]={report.count,report.frames,report.usable_bins,report.total_bins,report.invalid_input,report.ready_mask,
 report.covariance_frames,report.covariance_used_bins,report.carrier_bins,report.carrier_usable_bins,report.carrier_max_gap,
 report.clipped_output[0],report.clipped_output[1],report.covariance_protected_rank_min,report.covariance_protected_rank_max};
 return n<sizeof(v)/sizeof(v[0])?v[n]:0;
}
EXPORT double full_sep_quality(unsigned n){
 const double v[]={report.target_error,report.max_null_leakage,report.max_weight_norm,report.min_sector_gain,report.max_sector_gain,
 report.max_sector_leakage,report.energy[0],report.energy[1],report.usable_energy[0],report.usable_energy[1]};
 return n<sizeof(v)/sizeof(v[0])?v[n]:0;
}
