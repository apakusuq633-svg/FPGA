/* Host-only export of synthetic/offline STFT observations. No device IO. */
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include "circular9_candidates.c"
#include "acoustic_circular9_image.h"
static c9_separation_workspace w;
static int16_t input[C9_SEARCH_RAW_FRAMES][9];
int main(int argc,char **argv){
 if(argc!=4)return 2;unsigned offset=(unsigned)strtoul(argv[2],0,10);FILE *f=fopen(argv[1],"rb");assert(f);assert(!fseek(f,(long)offset*18,SEEK_SET));assert(fread(input,sizeof(input),1,f)==1);fclose(f);
 c9_search_context ctx={.first_sample=offset,.end_sample=offset+C9_SEARCH_RAW_FRAMES,.session=1,.epoch=1,.geometry_version=ACOUSTIC_GEOMETRY_VERSION};c9_search_feedback result;
 assert(c9_candidates_search(input,C9_SEARCH_RAW_FRAMES,acoustic_steer_lut,&w,&ctx,&result));
 f=fopen(argv[3],"wb");assert(f);uint32_t header[4]={w.analysis_frames,result.count,result.invalid_input,result.count?result.candidates[0].grid:0};fwrite(header,4,4,f);
 fwrite(w.observed,sizeof(w.observed),1,f);
 double q[1025][9];
 for(unsigned g=0;g<1025;g++){
  c9_candidate c=g<1024?(c9_candidate){.grid=g,.score=1}:result.candidates[0];int32_t az=0,el=0;c9_candidate_angles(&c,&az,&el);
  for(unsigned ch=0;ch<9;ch++)q[g][ch]=delay_q4(acoustic_steer_lut,ch,az,el);
 }
 fwrite(q,sizeof(q),1,f);fclose(f);printf("OFFLINE_OBSERVATIONS_EXPORTED frames=%u candidates=%u invalid=%u\n",w.analysis_frames,result.count,result.invalid_input);return 0;
}
