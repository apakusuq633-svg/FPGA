#ifndef CIRCULAR9_JOINT_SHADOW_H
#define CIRCULAR9_JOINT_SHADOW_H
#ifndef C9_JOINT_FORMAL
#define C9_JOINT_FORMAL 0
#endif
#ifndef C9_JOINT_SHADOW
#define C9_JOINT_SHADOW 0
#endif
#ifndef C9_JOINT_SHADOW_BUDGET_US
#define C9_JOINT_SHADOW_BUDGET_US 2000u
#endif
#if C9_JOINT_SHADOW || C9_JOINT_FORMAL
/* Independent observation only. No feedback into candidates/tracks/diagnosis. */
enum {C9_JOINT_OK=1,C9_JOINT_BUDGET=2,C9_JOINT_INVALID=3,C9_JOINT_NO_BANDS=4};
typedef struct {
 uint32_t status,count,raw_peaks,band_mask,total_us,score_us,peak_us,support_us,budget_us;
 c9_candidate raw_candidates[3];uint32_t raw_quality[3];int32_t raw_shoulder[3];uint32_t selected_raw_index[3];
 c9_candidate candidates[3];uint32_t quality[3],support_band_mask[3],support_mask[3];
 int32_t shoulder[3],direction_q30[3][3];
} c9_joint_report;
void c9_joint_shadow_compute(const c9_separation_workspace*,const uint32_t*,uint32_t,uint32_t,c9_joint_report*);
#endif
#endif
