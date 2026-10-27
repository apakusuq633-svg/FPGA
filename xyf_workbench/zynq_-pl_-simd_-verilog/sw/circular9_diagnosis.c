#include "circular9_diagnosis.h"
#include "circular9_envelope.h"
#include <float.h>
#include <string.h>

/* Explicit build override only; an archived 6205 model can never be a fallback. */
#ifdef C9_DIAG_MODEL_HEADER
#include C9_DIAG_MODEL_HEADER
#else
static const c9_diag_model c9_configured_diag_model = {0};
#endif
#ifdef C9_FSTF_EXPERIMENTAL
#include "fstf_c9f2_experimental_model.h"
#endif
unsigned c9_fstf_experiment_enabled(void){
#ifdef C9_FSTF_EXPERIMENTAL
 return 1;
#else
 return 0;
#endif
}
const char *c9_fstf_class_name(unsigned value){
 static const char *names[]={"inner","outer","ball","healthy","looseness","combined"};
 return value<6?names[value]:"unknown";
}
static void c9_fstf_experiment(c9_diag_report *r){
#ifdef C9_FSTF_EXPERIMENTAL
 const unsigned required=C9_DIAG_BIND_SNAPSHOT|C9_DIAG_BIND_STABLE|C9_DIAG_BIND_SEPARATED;
 if(!r||r->feature_contract!=C9_DIAG_FEATURE_CONTRACT||!r->binding.track_id||r->binding.grid>=1024u||r->extraction.status!=C9_DIAG_EXTRACT_OK||r->extraction.fft_count!=1u||
    r->shaft_hz<29.999999||r->shaft_hz>30.000001||r->clipped_samples>40u||
    r->binding.sample_count!=C9_DIAG_SAMPLES||(r->binding.flags&required)!=required||
    r->binding.separation_contract!=C9_DIAG_SEPARATION_CONTRACT)return;
 unsigned any_mask=0;for(unsigned k=0;k<7;k++)any_mask|=r->binding.usable_mask[k];
 if(!any_mask||r->binding.usable_mask[6]>1023u)return;
 double distance[6];int best=fstf_predict(r->features,distance);if(best<0)return;
 unsigned second=best?0u:1u;
 for(unsigned i=0;i<6;i++)if((int)i!=best&&distance[i]<distance[second])second=i;
 r->fstf_available=1;r->fstf_class=(unsigned)best;r->fstf_version=1;
 r->fstf_distance=distance[best];r->fstf_margin=distance[second]/(distance[best]>1e-12?distance[best]:1e-12);
 /* No writes to label, provisional_label, reason or fault_direction_valid. */
#else
 (void)r;
#endif
}
static int finite_number(double x) { return x==x && x<=DBL_MAX && x>=-DBL_MAX; }
const c9_diag_model *c9_diag_configured_model(void) { return &c9_configured_diag_model; }
const char *c9_diag_label_name(uint32_t v) {
 static const char *names[]={"unknown","normal","fault","interference","anomaly"};
 return v<5?names[v]:"unknown";
}
const char *c9_diag_reason_name(uint32_t v) {
 static const char *names[]={"ok","no_model","bad_model","bad_input","bad_binding",
  "silent","rejected","unvalidated","clipped","unseen_separation_filter","no_carrier"};
 return v<11?names[v]:"bad_input";
}
static int model_valid(const c9_diag_model *m) {
 if(!m || m->kind<1 || m->kind>2 || m->abi!=C9_DIAG_MODEL_ABI ||
    m->feature_contract!=C9_DIAG_FEATURE_CONTRACT || !m->version || m->validated>1 ||
    !finite_number(m->shaft_hz_min) || !finite_number(m->shaft_hz_max) ||
    m->shaft_hz_min<10.0 || m->shaft_hz_max>30.0 || m->shaft_hz_min>m->shaft_hz_max ||
    !finite_number(m->rms_min) || m->rms_min<=0.0 ||
    !finite_number(m->minimum_margin) || m->minimum_margin<=1.0 ||
    !finite_number(m->anomaly_multiplier) || m->anomaly_multiplier<=1.0 ||
    m->separation_contract!=C9_DIAG_SEPARATION_CONTRACT || !m->mask_count ||
    m->mask_count>C9_DIAG_FILTER_VARIANTS)return 0;
 for(unsigned k=0;k<m->mask_count;k++) {
  uint32_t any=0;
  for(unsigned j=0;j<C9_DIAG_MASK_WORDS;j++)any|=m->allowed_masks[k][j];
  if(!any || m->allowed_masks[k][6]>1023u)return 0;
 }
 for(unsigned i=0;i<C9_DIAG_FEATURES;i++) {
  if(!finite_number(m->inverse_variance[i]) || m->inverse_variance[i]<=0.0)return 0;
  for(unsigned c=0;c<(m->kind==2?3u:1u);c++)if(!finite_number(m->center[c][i]))return 0;
 }
 for(unsigned c=0;c<(m->kind==2?3u:1u);c++)
  if(!finite_number(m->radius[c]) || m->radius[c]<=0.0)return 0;
 return 1;
}
void c9_diag_score_features(const double v[C9_DIAG_FEATURES], double rms,
 double hz,const c9_diag_binding *b,const c9_diag_model *m,c9_diag_report *r) {
 if(!r)return;
 memset(r,0,sizeof(*r));
 if(b)r->binding=*b;
 r->feature_contract=C9_DIAG_FEATURE_CONTRACT;r->rms=rms;r->shaft_hz=hz;
 if(m){r->model_version=m->version;r->model_kind=m->kind;r->model_validated=m->validated==1;}
 if(!v || !finite_number(rms) || rms<0.0 || !finite_number(hz) || hz<10.0 || hz>30.0) {
  r->reason=C9_DIAG_BAD_INPUT;return;
 }
 for(unsigned i=0;i<C9_DIAG_FEATURES;i++) {
  if(!finite_number(v[i])){r->reason=C9_DIAG_BAD_INPUT;return;}
  r->features[i]=v[i];
 }
 if(!b || !b->track_id || b->sample_count!=C9_DIAG_SAMPLES ||
    (b->flags&C9_DIAG_BIND_REQUIRED)!=C9_DIAG_BIND_REQUIRED ||
    b->separation_contract!=C9_DIAG_SEPARATION_CONTRACT || b->usable_mask[6]>1023u) {
  r->reason=C9_DIAG_BAD_BINDING;return;
 }
 if(!m || !m->kind){r->reason=C9_DIAG_NO_MODEL;return;}
 if(!model_valid(m)){r->model_validated=0;r->reason=C9_DIAG_BAD_MODEL;return;}
 int known_filter=0;
 for(unsigned k=0;k<m->mask_count;k++)
  if(!memcmp(b->usable_mask,m->allowed_masks[k],sizeof(b->usable_mask)))known_filter=1;
 if(!known_filter){r->reason=C9_DIAG_BAD_FILTER;return;}
 if(hz<m->shaft_hz_min || hz>m->shaft_hz_max){r->reason=C9_DIAG_BAD_INPUT;return;}
 if(rms<m->rms_min){r->reason=C9_DIAG_SILENT;return;}
 unsigned classes=m->kind==2?3u:1u,best=0,second=1;
 for(unsigned c=0;c<classes;c++) {
  double d=0.0;
  for(unsigned i=0;i<C9_DIAG_FEATURES;i++){
   double z=v[i]-m->center[c][i];d+=z*z*m->inverse_variance[i]/C9_DIAG_FEATURES;
  }
  if(!finite_number(d)){r->reason=C9_DIAG_BAD_INPUT;return;}
  r->distance[c]=d;
 }
 if(m->kind==1) {
  if(r->distance[0]<=m->radius[0])r->provisional_label=C9_DIAG_NORMAL;
  else if(r->distance[0]>=m->radius[0]*m->anomaly_multiplier)r->provisional_label=C9_DIAG_ANOMALY;
 }else {
  for(unsigned c=1;c<3;c++)if(r->distance[c]<r->distance[best])best=c;
  second=best==0?1:0;
  for(unsigned c=0;c<3;c++)if(c!=best && r->distance[c]<r->distance[second])second=c;
  r->margin=r->distance[second]/(r->distance[best]>1e-12?r->distance[best]:1e-12);
  if(r->distance[best]<=m->radius[best] && r->margin>=m->minimum_margin)
   r->provisional_label=best+1;
 }
 if(!r->provisional_label){r->reason=C9_DIAG_REJECTED;return;}
 if(!m->validated){r->reason=C9_DIAG_UNVALIDATED;return;}
 r->label=r->provisional_label;r->reason=C9_DIAG_OK;
 r->fault_direction_valid=r->label==C9_DIAG_FAULT;
}
void c9_diagnose_with_model(const double x[C9_DIAG_SAMPLES],double hz,
 const c9_diag_binding *b,const c9_diag_model *m,c9_diag_report *r) {
 double v[C9_DIAG_FEATURES]={0},energy=0.0;unsigned clipped=0;
 if(!r)return;
 if(!x || !finite_number(hz) || hz<10.0 || hz>30.0) {
  c9_diag_score_features(0,0.0,hz,b,m,r);r->extraction.status=C9_DIAG_EXTRACT_BAD_INPUT;
  /* Unknown speed is exactly0 in the task ABI. Display the real envelope,
   * but leave order features/classification UNKNOWN; never substitute RPM. */
  if(x&&hz==0.0&&c9_env_analyze(x,&r->extraction)){
   for(unsigned i=0;i<C9_DIAG_SAMPLES;i++){energy+=x[i]*x[i];if(x[i]>=.999||x[i]<=-.999)clipped++;}
   r->rms=d_sqrt(energy/C9_DIAG_SAMPLES);r->clipped_samples=clipped;
  }
  return;
 }
 for(unsigned i=0;i<C9_DIAG_SAMPLES;i++) {
  if(!finite_number(x[i]) || x[i]>1.0 || x[i]<-1.0) {
   c9_diag_score_features(0,0.0,hz,b,m,r);r->extraction.status=C9_DIAG_EXTRACT_BAD_INPUT;return;
  }
  energy+=x[i]*x[i];if(x[i]>=0.999 || x[i]<=-0.999)clipped++;
 }
 c9_diag_extraction extraction;
 if(!c9_env_extract(x,hz,v,&extraction)) {
  c9_diag_score_features(0,0.0,hz,b,m,r);r->extraction=extraction;return;
 }
 c9_diag_score_features(v,d_sqrt(energy/C9_DIAG_SAMPLES),hz,b,m,r);
 r->extraction=extraction;
 if(extraction.status==C9_DIAG_EXTRACT_NO_CARRIER && m && m->kind) {
  r->label=r->provisional_label=C9_DIAG_UNKNOWN;r->fault_direction_valid=0;
  r->reason=C9_DIAG_NO_CARRIER;
 }
 r->clipped_samples=clipped;
 if(clipped>40u){r->label=r->provisional_label=C9_DIAG_UNKNOWN;r->fault_direction_valid=0;r->reason=C9_DIAG_CLIPPED;}
 c9_fstf_experiment(r);
}
void c9_diagnose(const double x[C9_DIAG_SAMPLES],double hz,
 const c9_diag_binding *b,c9_diag_report *r) {
 c9_diagnose_with_model(x,hz,b,c9_diag_configured_model(),r);
}

/* Display-only grouping of the already computed C9F2 FFT, 0..900Hz.
 * DC excluded. No changes to features, filters, model or normalization. */
void c9_diag_export_envelope(uint16_t bins[128]) {
 double maximum=0;unsigned last=(unsigned)(900.0*C9_ENV_FFT/C9_ENV_RATE);
 for(unsigned k=1;k<=last;k++)if(c9_env_spectrum[k]>maximum)maximum=c9_env_spectrum[k];
 for(unsigned i=0;i<128;i++){
  unsigned begin=(unsigned)(i*900.0*C9_ENV_FFT/(128.0*C9_ENV_RATE));
  unsigned end=(unsigned)((i+1u)*900.0*C9_ENV_FFT/(128.0*C9_ENV_RATE));
  if(!begin)begin=1;
  double value=0;for(unsigned k=begin;k<=end;k++)if(c9_env_spectrum[k]>value)value=c9_env_spectrum[k];
  bins[i]=maximum>0?(uint16_t)(value/maximum*1000.0+.5):0;
 }
}
