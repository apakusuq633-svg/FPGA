#include "circular9_diagnosis.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
static double audio[C9_DIAG_SAMPLES];
static c9_diag_model fixture(void) {
 /* Synthetic score-space fixture only, never an installed machine model. */
 c9_diag_model m={0};m.abi=C9_DIAG_MODEL_ABI;m.feature_contract=C9_DIAG_FEATURE_CONTRACT;
 m.version=17;m.kind=2;m.shaft_hz_min=10;m.shaft_hz_max=30;m.rms_min=.001;
 m.minimum_margin=1.25;m.anomaly_multiplier=2;
 m.separation_contract=C9_DIAG_SEPARATION_CONTRACT;m.mask_count=1;
 for(unsigned j=0;j<7;j++)m.allowed_masks[0][j]=j<6?0xffffffffu:1023u;
 for(unsigned i=0;i<18;i++){
  m.inverse_variance[i]=1;m.center[1][i]=10;m.center[2][i]=-10;
 }
 for(unsigned c=0;c<3;c++)m.radius[c]=2;
 return m;
}
int main(void) {
 c9_diag_binding b={7,123,44,90000,40000,C9_DIAG_BIND_REQUIRED,-12500,0};
 b.separation_contract=C9_DIAG_SEPARATION_CONTRACT;
 for(unsigned j=0;j<7;j++)b.usable_mask[j]=j<6?0xffffffffu:1023u;
 c9_diag_report r;c9_diag_model m=fixture();double v[18]={0};
 c9_diag_score_features(v,.1,25,&b,0,&r);
 assert(r.reason==C9_DIAG_NO_MODEL && r.label==C9_DIAG_UNKNOWN);
 c9_diag_score_features(v,.1,25,&b,&m,&r);
 assert(r.provisional_label==C9_DIAG_NORMAL && r.label==C9_DIAG_UNKNOWN);
 assert(r.reason==C9_DIAG_UNVALIDATED && !r.fault_direction_valid);
 for(unsigned i=0;i<18;i++)v[i]=10;
 m.validated=1;c9_diag_score_features(v,.1,25,&b,&m,&r);
 assert(r.label==C9_DIAG_FAULT && r.fault_direction_valid);
 assert(!memcmp(&r.binding,&b,sizeof(b)) && r.model_version==17);
 b.usable_mask[0]^=1;
 c9_diag_score_features(v,.1,25,&b,&m,&r);
 assert(r.reason==C9_DIAG_BAD_FILTER && !r.fault_direction_valid);
 b.usable_mask[0]^=1;
 /* Every independently required binding bit must prevent a fault direction. */
 for(unsigned i=0;i<4;i++){
  b.flags=C9_DIAG_BIND_REQUIRED^(1u<<i);
  c9_diag_score_features(v,.1,25,&b,&m,&r);
  assert(r.reason==C9_DIAG_BAD_BINDING && !r.fault_direction_valid);
 }
 b.flags=C9_DIAG_BIND_REQUIRED;b.sample_count=39999;
 c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.reason==C9_DIAG_BAD_BINDING);
 b.sample_count=40000;
 for(unsigned i=0;i<18;i++)v[i]=-10;
 c9_diag_score_features(v,.1,25,&b,&m,&r);
 assert(r.label==C9_DIAG_INTERFERENCE && !r.fault_direction_valid);
 for(unsigned i=0;i<18;i++)v[i]=5;
 c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.reason==C9_DIAG_REJECTED);
 c9_diag_score_features(v,.0001,25,&b,&m,&r);assert(r.reason==C9_DIAG_SILENT);
 v[0]=NAN;c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.reason==C9_DIAG_BAD_INPUT);
 v[0]=0;m.inverse_variance[0]=INFINITY;
 c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.reason==C9_DIAG_BAD_MODEL && !r.model_validated);
 m=fixture();m.validated=1;m.kind=1;
 c9_diag_score_features(v,.1,25,&b,&m,&r);
 assert(r.label==C9_DIAG_ANOMALY && !r.fault_direction_valid);
 for(unsigned i=0;i<18;i++)v[i]=0;
 c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.label==C9_DIAG_NORMAL);
 m.feature_contract^=1;
 c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.reason==C9_DIAG_BAD_MODEL);
 m.feature_contract=0x43394631u; /* Archived C9F1 may never silently score C9F2. */
 c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.reason==C9_DIAG_BAD_MODEL);
 m=fixture();m.separation_contract=0x43395332u;
 c9_diag_score_features(v,.1,25,&b,&m,&r);assert(r.reason==C9_DIAG_BAD_MODEL);
 b.separation_contract=0x43395332u;
 c9_diag_score_features(v,.1,25,&b,0,&r);assert(r.reason==C9_DIAG_BAD_BINDING);
 b.separation_contract=C9_DIAG_SEPARATION_CONTRACT;
 c9_diagnose(audio,25,&b,&r);
 assert(r.reason==C9_DIAG_NO_MODEL && r.feature_contract==C9_DIAG_FEATURE_CONTRACT);
 assert(r.extraction.status==C9_DIAG_EXTRACT_NO_CARRIER && r.extraction.fft_count==1);
 assert(r.extraction.envelope_samples==2500 && r.extraction.fft_size==4096);
 assert(fabs(r.extraction.observation_seconds-1.024)<1e-14);
 assert(r.extraction.hann_enbw_hz>1.46 && r.extraction.hann_first_null_hz>1.95);
 for(unsigned i=0;i<18;i++)assert(isfinite(r.features[i]));
 for(unsigned i=0;i<C9_DIAG_SAMPLES;i++)audio[i]=.1*sin(6.283185307179586*3000*i/39062.5);
 c9_diagnose(audio,25,&b,&r);assert(r.reason==C9_DIAG_NO_MODEL);
 assert(r.extraction.status==C9_DIAG_EXTRACT_NO_MODULATION);
 assert(fabs(r.rms-.1/sqrt(2))<1e-5);
 c9_diagnose(audio,NAN,&b,&r);assert(r.reason==C9_DIAG_BAD_INPUT);
 for(unsigned i=0;i<41;i++)audio[i]=1;
 c9_diagnose(audio,25,&b,&r);
 assert(r.reason==C9_DIAG_CLIPPED && r.clipped_samples==41 && !r.fault_direction_valid);
 audio[0]=NAN;c9_diagnose(audio,10,&b,&r);assert(r.reason==C9_DIAG_BAD_INPUT);
 audio[0]=1.001;c9_diagnose(audio,30,&b,&r);assert(r.reason==C9_DIAG_BAD_INPUT);
 for(unsigned i=0;i<C9_DIAG_SAMPLES;i++)audio[i]=.4;
 m=fixture();m.validated=1;
 c9_diagnose_with_model(audio,10,&b,&m,&r);
 assert(r.reason==C9_DIAG_NO_CARRIER && r.extraction.status==C9_DIAG_EXTRACT_NO_CARRIER);
 assert(r.label==C9_DIAG_UNKNOWN && !r.fault_direction_valid);
 puts("CIRCULAR9_DIAGNOSIS_PASS fixture_model_only default_model=NONE");
 return 0;
}
