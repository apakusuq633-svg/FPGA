/* Score-space guards only, not acoustic validation. */
#include <assert.h>
#include <stdio.h>
#include "circular9_diagnosis.c"
static c9_diag_report valid(void){c9_diag_report r={0};r.reason=C9_DIAG_NO_MODEL;r.feature_contract=C9_DIAG_FEATURE_CONTRACT;r.binding.track_id=1;r.binding.usable_mask[0]=1;r.binding.sample_count=40000;r.binding.flags=14;r.binding.separation_contract=C9_DIAG_SEPARATION_CONTRACT;r.shaft_hz=30;r.extraction.status=C9_DIAG_EXTRACT_OK;r.extraction.fft_count=1;return r;}
int main(void){
#ifdef C9_FSTF_EXPERIMENTAL
 for(unsigned c=0;c<6;c++){c9_diag_report r=valid();memcpy(r.features,fstf_center[c],sizeof(r.features));c9_fstf_experiment(&r);assert(r.fstf_available&&r.fstf_class==c&&r.label==0&&!r.fault_direction_valid&&r.reason==C9_DIAG_NO_MODEL);}
 for(unsigned k=0;k<10;k++){c9_diag_report r=valid();if(k==0)r.shaft_hz=0;if(k==1)r.shaft_hz=25;if(k==2)r.binding.flags&=~C9_DIAG_BIND_SEPARATED;if(k==3)r.extraction.fft_count=0;if(k==4)r.extraction.status=C9_DIAG_EXTRACT_NO_CARRIER;if(k==5)r.clipped_samples=41;if(k==6)r.binding.separation_contract=0;if(k==7)r.binding.track_id=0;if(k==8)r.feature_contract=0;if(k==9)r.binding.usable_mask[0]=0;c9_fstf_experiment(&r);assert(!r.fstf_available&&r.label==0&&!r.fault_direction_valid);}
#else
 c9_diag_report r=valid();c9_fstf_experiment(&r);assert(!c9_fstf_experiment_enabled()&&!r.fstf_available);
#endif
 puts("FSTF_ADAPTER_GUARDS_PASS no_trusted_label_override=1");return 0;
}
