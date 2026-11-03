/* Native engineering test: actual raw-nine-channel -> anti-alias/STFT LCMV
 * implementation, not an oracle that calls the separation code itself. */
#include "circular9_candidates.h"
#include "circular9_direction.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static c9_history history;
static int16_t raw[C9_SNAPSHOT_FRAMES][9],owned[C9_SNAPSHOT_FRAMES][9];
static c9_separation_workspace workspace;
static double audio[3][C9_AUDIO_FRAMES],sum_audio[C9_AUDIO_FRAMES];
static uint32_t lut[9*1024];
static c9_complex learned_weights[2][C9_CANDIDATES][C9_SEPARATION_FFT/2+1][9];
static c9_separation_report learned_report[2];
static int fail;
#define CHECK(c,m) do{if(!(c)){fprintf(stderr,"FAIL %s line%d\n",m,__LINE__);fail++;}}while(0)
static uint32_t rng=0x19327561;
static uint32_t random32(void){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void packet(uint32_t w[16],uint32_t seq,uint32_t epoch){
 memset(w,0,64);w[1]=seq;w[14]=epoch;
 for(unsigned ch=0;ch<9;ch++){
  int16_t value=(int16_t)(((seq+97*ch)&16383)-8192);
  w[8+ch/2]|=(uint32_t)(uint16_t)value<<(16*(ch&1));
 }
}
static void push_range(uint32_t begin,unsigned count,uint32_t epoch){
 uint32_t w[16];for(unsigned i=0;i<count;i++){packet(w,begin+i,epoch);c9_history_push(&history,w);}
}
static int check_owned(uint32_t first){
 for(unsigned i=0;i<C9_SNAPSHOT_FRAMES;i++)for(unsigned ch=0;ch<9;ch++)
  if(owned[i][ch]!=(int16_t)((((first+i)+97*ch)&16383)-8192))return 0;
 return 1;
}
static void *writer(void *arg){push_range(*(uint32_t*)arg,800000,7);return NULL;}
static void history_tests(void){
 uint32_t first=0,epoch=0,session=0;
 c9_history_init(&history);
 CHECK(!c9_history_snapshot(&history,owned,&first,&epoch,&session),"empty snapshot");
 /* Include uint32 sequence wrap, which must be an ordinary continuous stream. */
 uint32_t begin=0u-C9_SNAPSHOT_FRAMES-100u;
 push_range(begin,C9_SNAPSHOT_FRAMES+200,3);
 CHECK(c9_history_snapshot(&history,owned,&first,&epoch,&session),"wrap snapshot");
 CHECK(check_owned(first)&&epoch==3,"all wrapped owned samples");
 uint32_t old_session=session;
 uint32_t slot=(first+100)&(C9_HISTORY_FRAMES-1),guard=history.frames[slot].guard;
 __atomic_store_n(&history.frames[slot].guard,guard|1u,__ATOMIC_RELEASE);
 CHECK(!c9_history_snapshot(&history,owned,&first,&epoch,&session),"in-flight write rejected");
 __atomic_store_n(&history.frames[slot].guard,guard,__ATOMIC_RELEASE);
 history.frames[slot].sequence++;
 CHECK(!c9_history_snapshot(&history,owned,&first,&epoch,&session),"wrong slot sequence rejected");
 history.frames[slot].sequence--;
 push_range(102,1,3); /* expected next is 100: a real gap */
 CHECK(!c9_history_snapshot(&history,owned,&first,&epoch,&session),"gap resets history");
 push_range(103,C9_SNAPSHOT_FRAMES+4,4);
 CHECK(c9_history_snapshot(&history,owned,&first,&epoch,&session),"epoch restart refills");
 CHECK(check_owned(first)&&epoch==4&&session>old_session,"epoch and session provenance");
 c9_history_reset(&history);
 CHECK(!c9_history_snapshot(&history,owned,&first,&epoch,&session),"explicit bad-packet reset");
 c9_history_init(&history);push_range(0,250000,7);
 uint32_t writer_start=250000;pthread_t thread;
 CHECK(!pthread_create(&thread,NULL,writer,&writer_start),"start concurrent writer");
 unsigned successes=0,rejected=0;
 for(unsigned i=0;i<12;i++){
  if(c9_history_snapshot(&history,owned,&first,&epoch,&session)){
   CHECK(check_owned(first)&&epoch==7,"concurrent copy cannot tear");successes++;
  }else rejected++;
 }
 pthread_join(thread,NULL);
 CHECK(c9_history_snapshot(&history,owned,&first,&epoch,&session),"post-concurrency snapshot");
 CHECK(check_owned(first),"post-concurrency samples");
 uint32_t exact_end=(history.end-1024u)&~3u;
 CHECK(c9_history_snapshot_at(&history,owned,exact_end,&first,&epoch,&session)&&first+C9_SNAPSHOT_FRAMES==exact_end&&check_owned(first),"exact diagnostic end does not drift at CPU1 start");
 CHECK(c9_history_copy(&history,owned,C9_SEARCH_RAW_FRAMES,exact_end,&first,&epoch,&session)&&first+C9_SEARCH_RAW_FRAMES==exact_end,"short exact auxiliary copy");
 for(unsigned n=0;n<C9_SEARCH_RAW_FRAMES;n++)CHECK(owned[n][0]==(int16_t)((((first+n)&16383)-8192)),"short-copy sequence matches requested interval");
 CHECK(!c9_history_snapshot_at(&history,owned,history.end+4u,&first,&epoch,&session),"future exact end rejected");
 CHECK(!c9_history_copy(&history,owned,C9_SEARCH_RAW_FRAMES,exact_end+1u,&first,&epoch,&session),"unaligned exact end rejected");
 int16_t before=owned[0][0];push_range(1050000,C9_HISTORY_FRAMES+1,7);
 CHECK(owned[0][0]==before,"owned snapshot survives producer overwrite");
 CHECK(!c9_history_snapshot_at(&history,owned,exact_end,&first,&epoch,&session),"overwritten exact requested interval rejected");
 CHECK(C9_HISTORY_FRAMES>=625000u,"raw history retains at least4seconds");
 CHECK(sizeof(history)<32u*1024*1024,"history within shared 32 MiB");
 printf("HISTORY_PASS concurrent_copies=%u rejected=%u bytes=%llu\n",successes,rejected,(unsigned long long)sizeof(history));
}
static void make_lut(void){
 for(unsigned ch=0;ch<9;ch++)for(unsigned g=0;g<1024;g++){
  double a=ch<8?ch*6.283185307179586/8:0;
  double x=ch<8?.030*cos(a):0,y=ch<8?.030*sin(a):0;
  /* tau relative to outer mic0, matching the generated alignment LUT. */
  double ux=c9_direction_unit_q30[g][0]/1073741824.0,uy=c9_direction_unit_q30[g][1]/1073741824.0;
  long q=(long)floor(((x-.030)*ux+y*uy)*156250/343*16);
  lut[ch*1024+g]=(uint32_t)q&16383;
 }
}
#define TONES 40u
static double oscillator[3][9][TONES][2],echo_oscillator[3][9][TONES][2],rotation[3][TONES][2];
static double amplitude[3]={.050,.010,.080},frequency_shift[3]={0},echo_gain;
static unsigned active_tones[3]={TONES,TONES,TONES},source_begin[3]={0},source_end[3]={C9_SNAPSHOT_FRAMES,C9_SNAPSHOT_FRAMES,C9_SNAPSHOT_FRAMES};
static double first_tone=2200,tone_step=125;
static void synthesize(const c9_candidate cand[3],unsigned mask,double angle_error_deg,double elevation_error_deg){
 memset(raw,0,sizeof(raw));
 for(unsigned t=0;t<TONES;t++){
  for(unsigned s=0;s<3;s++){
   double frequency=first_tone+frequency_shift[s]+tone_step*t,phase=6.283185307179586*frequency/156250;
   rotation[s][t][0]=cos(phase);rotation[s][t][1]=sin(phase);
   double random_phase=(random32()/4294967296.0)*6.283185307179586;
   double az=(c9_direction_azimuth_mdeg[cand[s].grid%32]*.001+angle_error_deg)*3.141592653589793/180;
   double el=(c9_direction_elevation_mdeg[cand[s].grid/32]*.001+elevation_error_deg)*3.141592653589793/180;
   double ux=sin(az)*cos(el),uy=sin(el);
   for(unsigned ch=0;ch<9;ch++){
    double ring_angle=ch<8?ch*6.283185307179586/8:0;
    double x=ch<8?.030*cos(ring_angle):0,y=ch<8?.030*sin(ring_angle):0;
    double delay=((x-.030)*ux+y*uy)/343;
    double p=random_phase+6.283185307179586*frequency*delay;
    oscillator[s][ch][t][0]=cos(p);oscillator[s][ch][t][1]=sin(p);
    double eu=sin(az+20*3.141592653589793/180)*cos(el-8*3.141592653589793/180),ev=sin(el-8*3.141592653589793/180);
    double reflected_delay=((x-.030)*eu+y*ev)/343-.008;
    double ep=random_phase+6.283185307179586*frequency*reflected_delay;
    echo_oscillator[s][ch][t][0]=cos(ep);echo_oscillator[s][ch][t][1]=sin(ep);
   }
  }
 }
 for(unsigned n=0;n<C9_SNAPSHOT_FRAMES;n++)for(unsigned ch=0;ch<9;ch++){
  double value=0;
  for(unsigned s=0;s<3;s++)if(mask&(1u<<s))for(unsigned t=0;t<active_tones[s];t++){
   double c=oscillator[s][ch][t][0],si=oscillator[s][ch][t][1];
   if(n>=source_begin[s]&&n<source_end[s])value+=amplitude[s]*si/sqrt(active_tones[s]/2.0);
   oscillator[s][ch][t][0]=c*rotation[s][t][0]-si*rotation[s][t][1];
   oscillator[s][ch][t][1]=si*rotation[s][t][0]+c*rotation[s][t][1];
   if(echo_gain){
    c=echo_oscillator[s][ch][t][0];si=echo_oscillator[s][ch][t][1];
    if(n>=source_begin[s]+1250u&&n<source_end[s])value+=echo_gain*amplitude[s]*si/sqrt(active_tones[s]/2.0);
    echo_oscillator[s][ch][t][0]=c*rotation[s][t][0]-si*rotation[s][t][1];
    echo_oscillator[s][ch][t][1]=si*rotation[s][t][0]+c*rotation[s][t][1];
   }
  }
  long v=lround(value*32768);if(v>32767)v=32767;if(v< -32768)v=-32768;raw[n][ch]=(int16_t)v;
 }
}
static double power(const double *x){double e=0;for(unsigned n=1024;n<C9_AUDIO_FRAMES-1024;n++)e+=x[n]*x[n];return e/(C9_AUDIO_FRAMES-2048);}
static const c9_candidate primary[3]={
 {.grid=16*32+5,.score=1000},{.grid=16*32+16,.score=300},{.grid=16*32+27,.score=2000}};
/* An independently generated, rotated Gaussian score lobe is deliberately
 * not the quadratic equation solved by the extractor. Add integer sensor-
 * style noise; the known continuously located source is the ground truth. */
static void score_lobes(const c9_candidate *centers,double da,double de,int noisy,int32_t scores[1024]){
 for(unsigned g=0;g<1024;g++){
  double az=c9_direction_azimuth_mdeg[g%32]*.001,el=c9_direction_elevation_mdeg[g/32]*.001,value=0;
  for(unsigned c=0;c<3;c++){
   double x=az-(c9_direction_azimuth_mdeg[centers[c].grid%32]*.001+da);
   double y=el-(c9_direction_elevation_mdeg[centers[c].grid/32]*.001+de);
   value+=centers[c].score*exp(-.5*(x*x/81+2*.25*x*y/99+y*y/121));
  }
  if(noisy)value+=(int)(random32()%7)-3;
  scores[g]=(int32_t)lround(value);
 }
}
static void refinement_tests(void){
 int32_t scores[1024];c9_candidate out[3];double max_error=0,coarse_error=0,fit_error=0;
 for(unsigned noisy=0;noisy<2;noisy++){
  score_lobes(primary,2.4,1.6,(int)noisy,scores);
  CHECK(c9_candidates_extract(scores,out)==3,"all Gaussian lobes retain weak direction");
  for(unsigned c=0;c<3;c++){
   unsigned source=3;for(unsigned s=0;s<3;s++)if(out[c].grid==primary[s].grid)source=s;
   CHECK(source<3,"fitted maximum remains bound to original coarse cell");if(source>=3)continue;
   int32_t az,el;c9_candidate_angles(&out[c],&az,&el);
   double da=az*.001-(c9_direction_azimuth_mdeg[primary[source].grid%32]*.001+2.4);
   double de=el*.001-(c9_direction_elevation_mdeg[primary[source].grid/32]*.001+1.6);
   double err=hypot(da,de);if(err>max_error)max_error=err;fit_error+=err;coarse_error+=hypot(2.4,1.6);
   CHECK(out[c].flags&C9_CANDIDATE_REFINED,"finite local maximum is refined");
   CHECK(out[c].uncertainty_mdeg>=3000,"refinement retains conservative physical uncertainty");
   CHECK(err<.9,"off-grid Gaussian angular fit below0.9degree in this fixture");
   c9_candidate direct;
   CHECK(c9_candidate_at_peak(scores,out[c].grid,&direct)&&direct.grid==out[c].grid&&
     direct.score==out[c].score&&direct.azimuth_mdeg==out[c].azimuth_mdeg&&
     direct.elevation_mdeg==out[c].elevation_mdeg&&direct.flags==out[c].flags&&
     direct.uncertainty_mdeg==out[c].uncertainty_mdeg,"public current-map peak helper exactly matches extraction");
   double u[3];c9_candidate_unit(&out[c],u);
   CHECK(fabs(u[0]-sin(az*3.141592653589793/180000)*cos(el*3.141592653589793/180000))<1e-12&&
         fabs(u[1]-sin(el*3.141592653589793/180000))<1e-12,"candidate direction unit follows refined angles");
  }
 }
 CHECK(fit_error<coarse_error*.3,"independent noisy map fitting improves angular error");
 c9_candidate rejected={.grid=99,.score=100,.flags=C9_CANDIDATE_REFINED};
 CHECK(!c9_candidate_at_peak(scores,primary[0].grid+1,&rejected)&&!rejected.score&&!rejected.flags,
       "a nearby positive nonmaximum cannot refresh historical direction metadata");
 CHECK(!c9_candidate_at_peak(scores,1024,&rejected)&&!rejected.score,"peak helper rejects out-of-range cell");
 CHECK(!c9_candidate_at_peak(NULL,0,&rejected)&&!rejected.flags,"peak helper rejects missing current map");
 CHECK(!c9_candidate_at_peak(scores,0,NULL),"peak helper rejects missing destination");
 memset(scores,0,sizeof(scores));scores[16*32]=1000;
 CHECK(!c9_candidate_at_peak(scores,0,&rejected),"peak helper rejects zero score");
 scores[0]= -1;CHECK(!c9_candidate_at_peak(scores,0,&rejected),"peak helper rejects negative score");scores[0]=0;
 CHECK(c9_candidates_extract(scores,out)==1&&!out[0].flags,"boundary vertex remains coarse");
 for(unsigned i=0;i<1024;i++)scores[i]=1000;
 CHECK(c9_candidates_extract(scores,out)>0&&!out[0].flags,"flat peak never claims refinement");
 for(unsigned i=0;i<1024;i++)scores[i]=INT32_MIN;
 scores[primary[1].grid]=INT32_MAX;
 CHECK(c9_candidates_extract(scores,out)==1,"full int32 contrast remains bounded");
 int32_t az,el;c9_candidate_angles(&out[0],&az,&el);
 CHECK(az==c9_direction_azimuth_mdeg[16]&&el==c9_direction_elevation_mdeg[16],"symmetric saturated score fit cannot overflow");
 printf("REFINEMENT_PASS max_fixture_error_deg=%.9f total_coarse_error_deg=%.9f total_fit_error_deg=%.9f\n",max_error,coarse_error,fit_error);
}
static void delay_tests(void){
 make_lut();uint32_t delays[9];unsigned vectors=0;
 for(unsigned g=0;g<1024;g++){
  c9_candidate c={.grid=g,.score=1};int minimum=0,q[9];
  for(unsigned ch=0;ch<9;ch++){q[ch]=(int)(lut[ch*1024+g]&16383u);if(q[ch]&8192)q[ch]-=16384;if(!ch||q[ch]<minimum)minimum=q[ch];}
  CHECK(c9_candidate_delays_q16(&c,lut,delays),"coarse calibrated steering accepted");
  for(unsigned ch=0;ch<9;ch++)CHECK(delays[ch]==(uint32_t)(q[ch]-minimum)*4096u,"coarse normalizedQ4 reconstruction is word exact");
  vectors++;
 }
 c9_candidate fine={.grid=16*32+16,.score=1,.azimuth_mdeg=5212,.elevation_mdeg=4412,.flags=C9_CANDIDATE_REFINED};
 CHECK(c9_candidate_delays_q16(&fine,lut,delays),"continuous calibrated steering accepted");
 double az=fine.azimuth_mdeg*3.141592653589793/180000,el=fine.elevation_mdeg*3.141592653589793/180000;
 int exact[9],minimum=0,max_error=0;
 for(unsigned ch=0;ch<9;ch++){
  double ring_angle=ch*6.283185307179586/8,x=ch<8?.03*cos(ring_angle):0,y=ch<8?.03*sin(ring_angle):0;
  exact[ch]=(int)floor(((x-.03)*sin(az)*cos(el)+y*sin(el))*156250/343*16);
  if(!ch||exact[ch]<minimum)minimum=exact[ch];
 }
 for(unsigned ch=0;ch<9;ch++){
  int error=(int)(delays[ch]/4096u)-(exact[ch]-minimum);if(error<0)error= -error;if(error>max_error)max_error=error;
 }
 CHECK(max_error<=2,"continuous physical-wavefront oracle bounds interpolation+quantization error");
 fine.flags=2;CHECK(!c9_candidate_delays_q16(&fine,lut,delays),"unknown fine flags fail without coarse fallback");
 fine.flags=C9_CANDIDATE_REFINED;fine.azimuth_mdeg=90000;
 CHECK(!c9_candidate_delays_q16(&fine,lut,delays),"out-of-cell angle fails without coarse fallback");
 c9_candidate coarse={.grid=0,.score=1};uint32_t q0=lut[0],q1=lut[1024];lut[0]=8191;lut[1024]=8192;
 CHECK(!c9_candidate_delays_q16(&coarse,lut,delays),"more than61sample span fails");lut[0]=q0;lut[1024]=q1;
 printf("DELAYS_PASS coarse_vectors=%u physical_offgrid_max_error_q4=%d\n",vectors,max_error);
}
static int feedback_has(const c9_search_feedback *r,const c9_candidate *truth){
 double u[3];c9_candidate_unit(truth,u);
 for(unsigned c=0;c<r->count;c++){
  double v[3];c9_candidate_unit(&r->candidates[c],v);
  if(u[0]*v[0]+u[1]*v[1]+u[2]*v[2]>cos(10*3.141592653589793/180))return 1;
 }
 return 0;
}
static void search_tests(void){
 const c9_candidate sources[3]={{.grid=16*32+5,.score=1000},{.grid=16*32+20,.score=100},{.grid=16*32+27,.score=2000}};
 c9_search_context context={.session=7,.epoch=3,.first_sample=80000,.end_sample=80000+C9_SEARCH_RAW_FRAMES,.geometry_version=99,.calibration_version=11,.geometry_confirmed=1};
 c9_search_feedback result;make_lut();first_tone=600;tone_step=30;frequency_shift[1]=2200;frequency_shift[2]=5000;active_tones[1]=6;amplitude[1]=.006;
 rng=0x19327561;synthesize(sources,7,0,0);
 CHECK(c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&context,&result),"actual raw multiband search");
 int32_t broadband[1024];unsigned bins=0;for(unsigned b=0;b<3;b++)bins+=result.band_bins[b];
 for(unsigned g=0;g<1024;g++){
  int64_t sum=0;for(unsigned b=0;b<3;b++)sum+=(int64_t)workspace.search_scores[b][g]*result.band_bins[b];
  broadband[g]=bins?(int32_t)(sum/bins):0;
 }
 c9_candidate wide[3];unsigned wide_count=c9_candidates_extract(broadband,wide);int wide_weak=0;
 for(unsigned i=0;i<wide_count;i++)if(c9_direction_within(wide[i].grid,sources[1].grid,1057429273))wide_weak=1;
 for(unsigned i=0;i<wide_count;i++)printf("BROAD_DIRECTION grid=%u az=%d el=%d score=%d\n",wide[i].grid,wide[i].azimuth_mdeg,wide[i].elevation_mdeg,wide[i].score);
 printf("MULTIBAND_PASS candidates=%u bands=%u frames=%u weak_in_broadband=%d weak_in_multiband=%d low_bins=%u middle_bins=%u high_bins=%u weak_vs_loudest_db=%.6f\n",result.count,result.band_valid_mask,result.analysis_frames,wide_weak,feedback_has(&result,&sources[1]),result.band_bins[0],result.band_bins[1],result.band_bins[2],20*log10(amplitude[1]/amplitude[2]));
 for(unsigned i=0;i<result.count;i++)printf("SEARCH_DIRECTION grid=%u az=%d el=%d bands=%u quality=%u support=%u\n",result.candidates[i].grid,result.candidates[i].azimuth_mdeg,result.candidates[i].elevation_mdeg,result.band_mask[i],result.quality_permille[i],result.support_frames[i]);
 CHECK(result.count==3&&feedback_has(&result,&sources[0])&&feedback_has(&result,&sources[1])&&feedback_has(&result,&sources[2]),"all three physical directions found from independent spectral bands");
 CHECK(!wide_weak&&feedback_has(&result,&sources[1]),"weak source absent as full-spectrum local peak is recovered by its spectral band");
 CHECK(c9_search_feedback_current(&result,context.end_sample+1000,7,3,99,11),"bound fresh feedback valid");
 c9_search_feedback malformed=result;malformed.support_first_sample[0]=context.first_sample-4u;
 CHECK(!c9_search_feedback_current(&malformed,context.end_sample,7,3,99,11),"support interval before actual input cannot refresh a track");
 malformed=result;malformed.support_mask[0]=0;
 CHECK(!c9_search_feedback_current(&malformed,context.end_sample,7,3,99,11),"claimed support without per-frame witnesses rejected");
 malformed=result;malformed.support_frames[0]=2;
 CHECK(!c9_search_feedback_current(&malformed,context.end_sample,7,3,99,11),"fewer than3 genuine supported STFTs rejected");
 CHECK(!c9_search_feedback_current(&result,context.end_sample-4u,7,3,99,11),"future feedback cannot be used before actual observation end");
 CHECK(!c9_search_feedback_current(&result,context.end_sample+C9_SEARCH_MAX_AGE_SAMPLES+1,7,3,99,11),"old spectral evidence never refreshes current peaks");
 CHECK(!c9_search_feedback_current(&result,context.end_sample,8,3,99,11)&&!c9_search_feedback_current(&result,context.end_sample,7,4,99,11)&&
       !c9_search_feedback_current(&result,context.end_sample,7,3,100,11)&&!c9_search_feedback_current(&result,context.end_sample,7,3,99,12),"session epoch geometry or calibration mismatch rejects feedback");
 echo_gain=.15;rng=0x19327561;synthesize(sources,7,0,0);
 for(unsigned n=0;n<C9_SEARCH_RAW_FRAMES;n++)for(unsigned ch=0;ch<9;ch++)raw[n][ch]+=(int16_t)((int)(random32()%61)-30);
 CHECK(c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&context,&result)&&feedback_has(&result,&sources[1]),"weak spectral direction survives15percent8ms spatial reflection and independent sensor noise in this fixture");
 printf("MULTIBAND_REVERB_PASS echo_gain=0.15 echo_delay_ms=8 sensor_noise_peak_pcm=30 candidates=%u weak_found=%d\n",result.count,feedback_has(&result,&sources[1]));
 echo_gain=0;
 source_begin[1]=8000;source_end[1]=8781;rng=0x19327561;synthesize(sources,7,0,0);
 CHECK(c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&context,&result),"short burst observed");
 CHECK(!feedback_has(&result,&sources[1]),"one5ms burst cannot label whole100ms direction interval stable");
 source_begin[1]=0;source_end[1]=C9_SNAPSHOT_FRAMES;
 rng=0x98761324;for(unsigned n=0;n<C9_SEARCH_RAW_FRAMES;n++)for(unsigned ch=0;ch<9;ch++)raw[n][ch]=(int16_t)((int)(random32()%1201)-600);
 CHECK(c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&context,&result)&&!result.invalid_input&&!result.count&&result.analysis_frames>=3,"uncorrelated sensor noise yields real no-source observation");
 memset(raw,0,sizeof(raw));CHECK(c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&context,&result)&&result.invalid_input&&!result.count,"silent raw input does not invent spectral candidates");
 context.end_sample++;CHECK(!c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&context,&result),"mismatched raw interval rejected");
 frequency_shift[1]=frequency_shift[2]=0;first_tone=2200;tone_step=125;active_tones[1]=TONES;amplitude[1]=.010;
 puts("MULTIBAND_NEGATIVE_CONTROLS_PASS");
}
static void colored_noise(void){
 rng=0x71493523;
 for(unsigned n=0;n<C9_SNAPSHOT_FRAMES;n++)for(unsigned ch=0;ch<9;ch++){
  int peak=ch==8?3000:20;int noise=(int)(random32()%(unsigned)(2*peak+1))-peak;
  int value=raw[n][ch]+noise;if(value>32767)value=32767;if(value< -32768)value= -32768;raw[n][ch]=(int16_t)value;
 }
}
static void covariance_tests(void){
 c9_separation_report report;double target[2],noise[2];echo_gain=.20;
 rng=0x19327561;synthesize(primary,7,3.0,0);colored_noise();
 for(unsigned method=0;method<2;method++){
  CHECK(c9_candidates_test_separate(raw,primary,3,lut,&workspace,audio,&learned_report[method],(int)method),"fit prior/actual covariance to same noisy reflected input");
  memcpy(learned_weights[method],workspace.weights,sizeof(workspace.weights));
 }
 for(unsigned method=0;method<2;method++){
  rng=0x19327561;synthesize(primary,2,3.0,0);memcpy(workspace.weights,learned_weights[method],sizeof(workspace.weights));
  CHECK(c9_candidates_test_render(raw,primary,3,lut,&workspace,audio,&report,&learned_report[method]),"fixed noisy-mixture weights isolate target plus its physical reflection");target[method]=power(audio[1]);
  memset(raw,0,sizeof(raw));colored_noise();memcpy(workspace.weights,learned_weights[method],sizeof(workspace.weights));
  CHECK(c9_candidates_test_render(raw,primary,3,lut,&workspace,audio,&report,&learned_report[method]),"same fitted transform isolates independent unequal sensor noise");noise[method]=power(audio[1]);
 }
 double prior_snr=10*log10(target[0]/noise[0]),observed_snr=10*log10(target[1]/noise[1]),gain=sqrt(target[1]/target[0]);
 printf("EMPIRICAL_NOISE_PASS prior_snr_db=%.6f empirical_snr_db=%.6f improvement_db=%.6f target_gain=%.9f covariance_bins=%u prior_ready=%u empirical_ready=%u\n",prior_snr,observed_snr,observed_snr-prior_snr,gain,learned_report[1].covariance_used_bins,learned_report[0].ready_mask,learned_report[1].ready_mask);
 CHECK(learned_report[1].covariance_used_bins>0&&learned_report[0].covariance_used_bins==0,"only empirical path actually consumes input statistics");
 CHECK(observed_snr>prior_snr+1,"observed covariance improves unequal-sensor-noise SNR by more than1dB in this fixture");
 CHECK(gain>.85&&gain<1.15,"empirical covariance preserves reflected offgrid target amplitude");
 CHECK(learned_report[1].max_weight_norm<=8&&learned_report[1].min_sector_gain>=.85*.85,"actual-statistics solution still obeys WNG/target-sector guards");
 /* The input is now dominated by the wanted wavefront. Target projection
  * plus the residual-power floor must not train that target as interference. */
 echo_gain=0;amplitude[0]=amplitude[2]=.0015;amplitude[1]=.08;
 rng=0x19327561;synthesize(primary,7,3.0,0);
 for(unsigned method=0;method<2;method++){
  CHECK(c9_candidates_test_separate(raw,primary,3,lut,&workspace,audio,&learned_report[method],(int)method),"target-dominated snapshot fit");
  memcpy(learned_weights[method],workspace.weights,sizeof(workspace.weights));
 }
 rng=0x19327561;synthesize(primary,2,3.0,0);
 for(unsigned method=0;method<2;method++){
  memcpy(workspace.weights,learned_weights[method],sizeof(workspace.weights));
  CHECK(c9_candidates_test_render(raw,primary,3,lut,&workspace,audio,&report,&learned_report[method]),"dominant true target retained under same learned weights");target[method]=power(audio[1]);
 }
 gain=sqrt(target[1]/target[0]);CHECK(gain>.85&&gain<1.15,"actual target covariance does not self-cancel dominant3degree target");
 printf("TARGET_PROTECTION_PASS target_gain=%.9f covariance_used_bins=%u protected_rank_min=%u\n",gain,learned_report[1].covariance_used_bins,learned_report[1].covariance_protected_rank_min);
 amplitude[0]=.050;amplitude[1]=.010;amplitude[2]=.080;
}
static void separation_tests(void){
 const c9_candidate *cand=primary;
 double separated[3][3],das[3];c9_separation_report r;make_lut();
 rng=0x19327561;synthesize(cand,7,0,0);
 CHECK(c9_candidates_separate(raw,cand,3,lut,&workspace,audio,&learned_report[0]),"learn from one actual mixed snapshot");
 memcpy(learned_weights[0],workspace.weights,sizeof(workspace.weights));
 for(unsigned source=0;source<3;source++){
  rng=0x19327561;synthesize(cand,1u<<source,0,0);
  memcpy(workspace.weights,learned_weights[0],sizeof(workspace.weights));
  CHECK(c9_candidates_test_render(raw,cand,3,lut,&workspace,audio,&r,&learned_report[0]),"frozen mixed-snapshot weights isolate known contribution");
  for(unsigned c=0;c<3;c++)separated[c][source]=power(audio[c]);
  for(unsigned n=0;n<C9_AUDIO_FRAMES;n++)sum_audio[n]+=audio[1][n];
  CHECK(c9_candidates_separate(raw,&cand[1],1,lut,&workspace,audio,&r),"DAS baseline contribution");
  das[source]=power(audio[0]);
 }
 rng=0x19327561;synthesize(cand,7,0,0);
 memcpy(workspace.weights,learned_weights[0],sizeof(workspace.weights));
 CHECK(c9_candidates_test_render(raw,cand,3,lut,&workspace,audio,&r,&learned_report[0]),"all three with same learned mixed-snapshot weights");
 double err=0,reference=0;
 for(unsigned n=1024;n<C9_AUDIO_FRAMES-1024;n++){
  double d=audio[1][n]-sum_audio[n];err+=d*d;reference+=sum_audio[n]*sum_audio[n];
 }
 double linearity=sqrt(err/reference);
 double snr=10*log10(separated[1][1]/(separated[1][0]+separated[1][2]));
 double baseline=10*log10(das[1]/(das[0]+das[2]));
 double gain=sqrt(separated[1][1]/das[1]);
 CHECK(snr-baseline>10,"weak target crosstalk improvement >10dB");
 CHECK(gain>.85&&gain<1.15,"target amplitude preserved");
 CHECK(linearity<.002,"same frozen learned transform obeys independent source superposition");
 CHECK(r.ready_mask==7&&!r.invalid_input,"all three actual broadband outputs ready");
 CHECK(r.target_error<1e-10&&r.max_null_leakage<=.01&&r.max_weight_norm<=8.0,"constraint and WNG guards");
 CHECK(r.min_sector_gain>=.85*.85&&r.max_sector_gain<=1.15*1.15&&r.max_sector_leakage<=.03,"modeled target and interference sectors remain within explicit limits");
 CHECK(r.carrier_usable_bins*20>=r.carrier_bins*19&&r.carrier_max_gap<=3,"fixed diagnostic carrier has no unsafe holes");
 printf("COVARIANCE_PASS frames=%u bins=%u used_bins=%u protected_rank_min=%u protected_rank_max=%u shrinkage_permille=%u\n",r.covariance_frames,r.covariance_bins,r.covariance_used_bins,r.covariance_protected_rank_min,r.covariance_protected_rank_max,r.covariance_shrinkage_permille);
 CHECK(r.covariance_frames==8&&r.covariance_used_bins>0&&r.covariance_protected_rank_min>=3,"actual input covariance used with protected target subspace");
 printf("SEPARATION_PASS target_vs_loudest_db=%.6f das_sir_db=%.6f separated_sir_db=%.6f improvement_db=%.6f target_gain=%.9f linearity_rmse=%.9f usable_bins=%u total_bins=%u ready_mask=%u\n",
 20*log10(amplitude[1]/amplitude[2]),baseline,snr,snr-baseline,gain,linearity,r.usable_bins,r.total_bins,r.ready_mask);
 /* Repeat the contribution measurement with true wavefronts three degrees
  * off the assumed candidates. This measures sensitivity, not just the ideal
  * algebraic identity. No fabricated front/back/range information is used. */
 rng=0x19327561;synthesize(cand,7,3.0,0);
 CHECK(c9_candidates_separate(raw,cand,3,lut,&workspace,audio,&learned_report[0]),"learn actual mismatch mixture");
 memcpy(learned_weights[0],workspace.weights,sizeof(workspace.weights));
 for(unsigned source=0;source<3;source++){
  rng=0x19327561;synthesize(cand,1u<<source,3.0,0);
  memcpy(workspace.weights,learned_weights[0],sizeof(workspace.weights));
  CHECK(c9_candidates_test_render(raw,cand,3,lut,&workspace,audio,&r,&learned_report[0]),"frozen actual mismatch contribution");
  for(unsigned c=0;c<3;c++)separated[c][source]=power(audio[c]);
  CHECK(c9_candidates_separate(raw,&cand[1],1,lut,&workspace,audio,&r),"mismatch DAS baseline");
  das[source]=power(audio[0]);
 }
 snr=10*log10(separated[1][1]/(separated[1][0]+separated[1][2]));
 baseline=10*log10(das[1]/(das[0]+das[2]));gain=sqrt(separated[1][1]/das[1]);
 CHECK(snr-baseline>10&&gain>.85&&gain<1.15,"three-degree mismatch still improves weak-target SIR");
 CHECK(snr>9.0,"sector regularization improves known3degree mismatch beyond9dB SIR");
 printf("MISMATCH_PASS angle_error_deg=3 das_sir_db=%.6f separated_sir_db=%.6f improvement_db=%.6f target_gain=%.9f\n",baseline,snr,snr-baseline,gain);
 /* Known off-grid plane waves are generated from continuous physical delays,
  * independently of the LUT and score fit. The same raw samples are supplied
  * to both coarse-cell and refined-angle processing. */
 int32_t fitted_map[1024];c9_candidate extracted[3],fine[3];
 score_lobes(cand,2.4,1.6,1,fitted_map);
 CHECK(c9_candidates_extract(fitted_map,extracted)==3,"offgrid separation candidates");
 for(unsigned c=0;c<3;c++)for(unsigned j=0;j<3;j++)if(extracted[j].grid==cand[c].grid)fine[c]=extracted[j];
 double coarse_contribution[3],fine_contribution[3];
 rng=0x19327561;synthesize(cand,7,2.4,1.6);
 CHECK(c9_candidates_separate(raw,cand,3,lut,&workspace,audio,&learned_report[0]),"learn actual offgrid mixture coarse");
 memcpy(learned_weights[0],workspace.weights,sizeof(workspace.weights));
 CHECK(c9_candidates_separate(raw,fine,3,lut,&workspace,audio,&learned_report[1]),"learn same offgrid mixture refined");
 memcpy(learned_weights[1],workspace.weights,sizeof(workspace.weights));
 for(unsigned source=0;source<3;source++){
  rng=0x19327561;synthesize(cand,1u<<source,2.4,1.6);
  memcpy(workspace.weights,learned_weights[0],sizeof(workspace.weights));
  CHECK(c9_candidates_test_render(raw,cand,3,lut,&workspace,audio,&r,&learned_report[0]),"frozen coarse offgrid contribution");
  coarse_contribution[source]=power(audio[1]);
  memcpy(workspace.weights,learned_weights[1],sizeof(workspace.weights));
  CHECK(c9_candidates_test_render(raw,fine,3,lut,&workspace,audio,&r,&learned_report[1]),"frozen refined offgrid contribution");
  fine_contribution[source]=power(audio[1]);
 }
 double coarse_sir=10*log10(coarse_contribution[1]/(coarse_contribution[0]+coarse_contribution[2]));
 double refined_sir=10*log10(fine_contribution[1]/(fine_contribution[0]+fine_contribution[2]));
 double relative_gain=sqrt(fine_contribution[1]/coarse_contribution[1]);
 CHECK(refined_sir>coarse_sir+8,"actual offgrid audio SIR improves with map angle fitting");
 CHECK(relative_gain>.85&&relative_gain<1.15,"refinement preserves weak target amplitude");
 printf("OFFGRID_PASS true_offset_az_deg=2.4 true_offset_el_deg=1.6 coarse_sir_db=%.6f refined_sir_db=%.6f improvement_db=%.6f relative_target_gain=%.9f\n",coarse_sir,refined_sir,refined_sir-coarse_sir,relative_gain);
 /* Independent sensor noise is amplified only within the explicit WNG cap.
  * Reference is the same mixed snapshot without that noise. */
 rng=0x19327561;synthesize(cand,7,0,0);
 CHECK(c9_candidates_separate(raw,cand,3,lut,&workspace,audio,&r),"noise-free mixed reference");
 memcpy(sum_audio,audio[1],sizeof(sum_audio));
 for(unsigned n=0;n<C9_SNAPSHOT_FRAMES;n++)for(unsigned ch=0;ch<9;ch++){
  int noise=(int)(random32()%69)-34;raw[n][ch]=(int16_t)(raw[n][ch]+noise);
 }
 CHECK(c9_candidates_separate(raw,cand,3,lut,&workspace,audio,&r)&&r.ready_mask==7,"independent sensor-noise fixture remains ready");
 err=0;reference=0;
 for(unsigned n=1024;n<C9_AUDIO_FRAMES-1024;n++){double d=audio[1][n]-sum_audio[n];err+=d*d;reference+=sum_audio[n]*sum_audio[n];}
 double noise_snr=10*log10(reference/err);
 CHECK(noise_snr>15,"weak output remains above independent sensor noise");
 printf("SENSOR_NOISE_PASS output_signal_to_added_noise_db=%.6f input_noise_rms_pcm=19.916\n",noise_snr);
 /* Failure controls cannot silently label unseparated audio as diagnosis-ready. */
 c9_candidate duplicate[3]={cand[0],cand[0],cand[2]};
 CHECK(!c9_candidates_separate(raw,duplicate,3,lut,&workspace,audio,&r)&&!r.ready_mask,"coincident candidates rejected");
 for(unsigned n=0;n<C9_SNAPSHOT_FRAMES;n++)raw[n][8]=0;
 CHECK(c9_candidates_separate(raw,cand,3,lut,&workspace,audio,&r)&&!r.ready_mask&&(r.invalid_input&(1u<<8)),"silent ninth microphone gates diagnosis");
 rng=0x19327561;synthesize(cand,7,0,0);raw[1000][4]=32767;
 CHECK(c9_candidates_separate(raw,cand,3,lut,&workspace,audio,&r)&&!r.ready_mask&&(r.invalid_input&(1u<<4)),"clipped input gates diagnosis");
 c9_candidate near[3]={{.grid=16*32+5,.score=1000},{.grid=16*32+10,.score=1000},{.grid=16*32+15,.score=1000}};
 rng=0x19327561;synthesize(near,7,0,0);
 CHECK(c9_candidates_separate(raw,near,3,lut,&workspace,audio,&r),"marginal directions processed");
 printf("MARGINAL_QUALITY usable_bins=%u total_bins=%u ready_mask=%u\n",r.usable_bins,r.total_bins,r.ready_mask);
 CHECK(r.usable_bins<r.total_bins,"ill-conditioned low-frequency bins rejected");
 /* High-frequency signal energy alone must not clear diagnosis when the
  * prescribed lower carrier includes spatially unsafe bins. */
 c9_candidate hole[3]={{.grid=16*32+10,.score=1000},{.grid=16*32+16,.score=300},{.grid=16*32+22,.score=2000}};
 first_tone=5000;tone_step=50;rng=0x19327561;synthesize(hole,7,0,0);
 CHECK(c9_candidates_separate(raw,hole,3,lut,&workspace,audio,&r),"carrier-hole geometry processed");
 printf("CARRIER_GUARD usable_energy_ratio=%.9f carrier_bins=%u carrier_usable_bins=%u carrier_max_gap=%u ready_mask=%u\n",r.usable_energy[1]/r.energy[1],r.carrier_bins,r.carrier_usable_bins,r.carrier_max_gap,r.ready_mask);
 CHECK(r.usable_energy[1]>.85*r.energy[1],"carrier-hole fixture passes former energy-only criterion");
 CHECK(!r.ready_mask&&r.carrier_usable_bins*20<r.carrier_bins*19,"fixed carrier holes veto energy-only false readiness");
 first_tone=2200;tone_step=125;
 c9_candidate invalid[3]={cand[0],cand[1],cand[2]};invalid[1].flags=C9_CANDIDATE_REFINED;
 invalid[1].azimuth_mdeg=15000;invalid[1].elevation_mdeg=2812;
 CHECK(!c9_candidates_separate(raw,invalid,3,lut,&workspace,audio,&r)&&!r.ready_mask,"impossible fitted angle does not fall back silently");
 /* Angular NMS must preserve a weak source while suppressing near-pole grid
  * aliases. No fault/normal label is inferred from the ordering or score. */
 int32_t scores[1024]={0};
 scores[cand[0].grid]=2000;scores[cand[1].grid]=300;scores[cand[2].grid]=1200;
 CHECK(c9_candidates_extract(scores,extracted)==3,"three peaks include weak candidate");
 memset(scores,0,sizeof(scores));scores[0]=2000;scores[31]=1800;
 CHECK(c9_candidates_extract(scores,extracted)==1,"pole aliases angularly suppressed");
 CHECK(c9_candidates_separate(NULL,cand,3,lut,&workspace,audio,&r)==0&&!r.ready_mask,"invalid argument not ready");
 printf("SEPARATION_NEGATIVE_CONTROLS_PASS\n");
}
int main(void){history_tests();refinement_tests();delay_tests();separation_tests();search_tests();covariance_tests();if(fail)return 1;puts("CIRCULAR9_CANDIDATES_PASS");return 0;}
