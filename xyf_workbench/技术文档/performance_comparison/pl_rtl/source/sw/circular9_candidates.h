#ifndef CIRCULAR9_CANDIDATES_H
#define CIRCULAR9_CANDIDATES_H
#include <stdint.h>
/* 6.7108864 seconds at156250Hz; guarded slots fit in32MiB shared RAM. */
#define C9_HISTORY_FRAMES 1048576u
#define C9_SNAPSHOT_FRAMES 160256u /* 1.024 s plus 256 raw samples warmup. */
#define C9_CANDIDATES 3u
#define C9_AUDIO_FRAMES 40000u
#define C9_SEPARATION_FFT 1024u
#define C9_SEPARATION_HOP 512u
#define C9_DECIMATED_FRAMES (C9_SNAPSHOT_FRAMES / 4u)
#define C9_SEARCH_RAW_FRAMES 16640u /*256warmup+104.8576ms of evidence. */
#define C9_SEARCH_MIN_RAW_FRAMES 8448u
#define C9_SEARCH_BANDS 3u
#define C9_SEARCH_FEEDBACK_ABI 0x43394232u /* C9B2: exact connected union of supported STFT windows */
#define C9_SEARCH_MAX_AGE_SAMPLES 31250u /*200ms after evidence end. */
#define C9_ANALYSIS_FRAMES 8u
#define C9_ANALYSIS_BINS 202u /* positive bins8..209 */
/* STFT windows have length1024 and hop512 after /4. Support at frame0
 * and frame2 has no temporal hole: the two real windows touch. Count at
 * least three actual witnesses, and never bridge a gap larger than one hop. */
static inline unsigned c9_support_component(uint32_t mask,unsigned frames,unsigned *first,unsigned *last){
 unsigned run=0,start=0,previous=0,best=0,best_span=0;*first=*last=0;
 if(frames>8u||(mask>>frames))return 0;
 for(unsigned f=0;f<frames;f++)if(mask&(1u<<f)){
  if(!run||f-previous>C9_SEPARATION_FFT/C9_SEPARATION_HOP){run=1;start=f;}else run++;
  previous=f;unsigned span=f-start;
  if(run>best||(run==best&&span>best_span)){best=run;best_span=span;*first=start;*last=f;}
 }
 return best;
}
typedef struct {uint32_t guard,sequence;int16_t pcm[9];} c9_history_frame;
typedef struct {
 uint32_t head_guard,end,count,epoch,session;
 c9_history_frame frames[C9_HISTORY_FRAMES];
} c9_history;
unsigned c9_candidates_acceleration(void); /* 7: ARM vector self-test passed; 3: fallback. */
#define C9_CANDIDATE_REFINED 1u
typedef struct {
 uint32_t grid;int32_t score;
 /* Grid remains the published PL cell identity. A fitted local maximum may
  * move by at most half a cell on each axis; it is not a precision claim.
  * flags==0 keeps legacy/grid-only observations fully supported. */
 int32_t azimuth_mdeg,elevation_mdeg;
 uint32_t flags,uncertainty_mdeg;
} c9_candidate;
typedef struct {double re,im;} c9_complex;
typedef struct {
 uint32_t session,epoch,first_sample,end_sample,geometry_version;
 uint32_t calibration_version,geometry_confirmed;
} c9_search_context;
typedef struct {
 uint32_t abi,count,session,epoch,first_sample,end_sample,valid_until_sample;
 uint32_t geometry_version,calibration_version,geometry_confirmed;
 uint32_t analysis_frames,band_valid_mask,invalid_input;
 c9_candidate candidates[C9_CANDIDATES];
 uint32_t band_mask[C9_CANDIDATES],quality_permille[C9_CANDIDATES];
 uint32_t support_first_sample[C9_CANDIDATES],support_end_sample[C9_CANDIDATES];
 uint32_t support_frames[C9_CANDIDATES],support_mask[C9_CANDIDATES];
 int32_t band_score[C9_CANDIDATES][C9_SEARCH_BANDS];
 uint32_t band_bins[C9_SEARCH_BANDS];
} c9_search_feedback;
typedef struct {
 /* CPU1-owned cached workspace. Never place in shared history section. */
 float decimated[9][C9_DECIMATED_FRAMES];
 c9_complex spectrum[9][C9_SEPARATION_FFT];
 c9_complex weights[C9_CANDIDATES][C9_SEPARATION_FFT/2+1][9];
 c9_complex transform[C9_SEPARATION_FFT],twiddle[C9_SEPARATION_FFT/2];
 double window[C9_SEPARATION_FFT],normalization[C9_AUDIO_FRAMES];
 /* Eight actual STFT observations, not a hand-built steering covariance. */
 c9_complex covariance[C9_ANALYSIS_BINS][9][9];
 c9_complex observed[C9_ANALYSIS_FRAMES][9][C9_ANALYSIS_BINS];
 uint32_t observed_start[C9_ANALYSIS_FRAMES];
 double band_energy[C9_ANALYSIS_FRAMES][C9_SEARCH_BANDS];
 double search_lags[36][64];
 int32_t search_scores[C9_SEARCH_BANDS][1024];
 uint32_t analysis_frames;
 /* CPU1-private DDR scratch. Its OCM stack is noncached; these arrays are
  * reused sequentially, never shared with an interrupting search/diagnosis. */
 double search_roots[9][C9_ANALYSIS_BINS];
 c9_complex bin_steering[3][5][9],bin_covariance[9][9],bin_inverse[9][9],bin_observed_covariance[9][9];
 uint32_t search_ticks[3]; /* Preparation, observations, search; ARM timer ticks. */
} c9_separation_workspace;
typedef struct {
 uint32_t count,frames,usable_bins,total_bins,invalid_input;
 uint32_t ready_mask; /* Only these outputs may be submitted for diagnosis. */
 uint32_t clipped_input[9],clipped_output[C9_CANDIDATES];
 uint32_t usable_mask[7]; /* bit (FFT bin - 8), 202 bins through 7972.7 Hz. */
 double target_error; /* Maximum absolute real+imaginary unity-response error. */
 double max_null_leakage; /* Power ratio, at most .01 on retained bins. */
 double max_weight_norm; /* Sum |w|^2, at most8 (9.03dB vs one sensor). */
 /* The fixed diagnostic analytic carrier must not silently lose a contiguous
  * frequency band, even when most energy happens to lie in retained bins. */
 uint32_t carrier_bins,carrier_usable_bins,carrier_max_gap;
 /* Power responses at center and four axis-offset sector samples. Physical
  * uncertainty remains metadata, not an accuracy guarantee between samples. */
 double min_sector_gain,max_sector_gain,max_sector_leakage;
 uint32_t covariance_frames,covariance_bins,covariance_used_bins;
 uint32_t covariance_protected_rank_min,covariance_protected_rank_max;
 uint32_t covariance_shrinkage_permille;
 /* Spectral quality proxy BEFORE masking unsafe bins; usable_energy excludes
  * the unsafe DAS proxy. Actual output always has those unsafe bins removed. */
 double energy[C9_CANDIDATES],usable_energy[C9_CANDIDATES];
} c9_separation_report;
/* CPU0 is sole writer. Reset on bad/dropped packets. Initializing PCM is
 * unnecessary: metadata plus each slot's write guard protect the reader. */
void c9_history_init(c9_history *s);
void c9_history_reset(c9_history *s);
void c9_history_push(c9_history *s,const uint32_t packet[16]);
int c9_history_info(const c9_history *s,uint32_t *end,uint32_t *count,
 uint32_t *epoch,uint32_t *session);
/* CPU1 copies to independently owned PCM. Zero on gaps, session/epoch changes,
 * concurrent slot writes, or overwrite. */
int c9_history_snapshot(const c9_history *s,int16_t (*pcm)[9],uint32_t *first,
 uint32_t *epoch,uint32_t *session);
int c9_history_copy(const c9_history *s,int16_t (*pcm)[9],uint32_t frames,
 uint32_t requested_end,uint32_t *first,uint32_t *epoch,uint32_t *session);
int c9_history_snapshot_at(const c9_history *s,int16_t (*pcm)[9],uint32_t requested_end,
 uint32_t *first,uint32_t *epoch,uint32_t *session);
unsigned c9_candidates_extract(const int32_t scores[1024],c9_candidate out[3]);
/* Fit one positive local maximum in the supplied committed map. A temporal
 * rank may choose a grid, but fresh direction metadata must come from the
 * current map. Returns0 and clears *out for a nonpeak/invalid argument. */
int c9_candidate_at_peak(const int32_t scores[1024],unsigned grid,
 c9_candidate *out);
void c9_candidate_angles(const c9_candidate *candidate,int32_t *azimuth_mdeg,
 int32_t *elevation_mdeg);
void c9_candidate_unit(const c9_candidate *candidate,double unit[3]);
/* Strict continuous-angle calibrated steering for atomic PL/PS commit.
 * Floor each interpolated signedQ4 value, normalize minimum to0, convertQ16.
 * Unsupported flags/angles/range fail; never fall back to a coarse grid. */
int c9_candidate_delays_q16(const c9_candidate *candidate,const uint32_t *steer_lut,
 uint32_t delays[9]);
/* No track is needed. raw_frames must be4aligned and8448..16640; context
 * bounds exactly match that owned raw segment. Uses up to eight actual STFTs,
 * coherence-weighted PHAT in600..2200/2200..4600/4600..8000Hz and36pairSRP.
 * Feedback is evidence for discovery, never a trusted/fault direction.
 * CPU0 MUST validate current session/epoch/geometry/calibration, monotonic end
 * and unsigned end-age<=31250 before using it; never refresh it by reuse. */
int c9_candidates_search(const int16_t (*raw)[9],uint32_t raw_frames,
 const uint32_t *steer_lut,c9_separation_workspace *workspace,
 const c9_search_context *context,c9_search_feedback *feedback);
int c9_search_feedback_current(const c9_search_feedback *feedback,uint32_t now_sample,
 uint32_t session,uint32_t epoch,uint32_t geometry_version,uint32_t calibration_version);
/* CPU1 synchronous bounded processing, same snapshot for all candidates.
 * Signed Q4 LUT delays use the original 156250-Hz clock. Anti-alias then
 * decimate 4:1 and apply regularized STFT constrained beamforming. Target
 * sectors are protected and other candidate sectors are softly suppressed;
 * norm, target response and leakage guards decide usable bins. Refined angle
 * steering interpolates the calibrated signed-Q4 LUT, without inventing a
 * second microphone geometry. Unsafe bins are zeroed in diagnostic audio;
 * ready_mask stays clear for excess removed energy OR holes in the fixed
 * 2200..4600-Hz diagnosis carrier. Exactly 40000
 * samples at 39062.5 Hz, passband 300..8000 Hz. This is spatial separation,
 * not a fault classifier or guaranteed blind source separation. */
int c9_candidates_separate(const int16_t (*raw)[9],const c9_candidate *candidates,
 unsigned count,const uint32_t *lut,c9_separation_workspace *workspace,
 double out[C9_CANDIDATES][C9_AUDIO_FRAMES],c9_separation_report *report);
#ifdef C9_CANDIDATES_TEST
/* Measurement-only native hooks: frozen weights learned from the SAME mixed
 * snapshot isolate contributions without refitting on each source separately. */
int c9_candidates_test_separate(const int16_t (*raw)[9],const c9_candidate *candidates,
 unsigned count,const uint32_t *lut,c9_separation_workspace *workspace,
 double out[C9_CANDIDATES][C9_AUDIO_FRAMES],c9_separation_report *report,int empirical);
int c9_candidates_test_render(const int16_t (*raw)[9],const c9_candidate *candidates,
 unsigned count,const uint32_t *lut,c9_separation_workspace *workspace,
 double out[C9_CANDIDATES][C9_AUDIO_FRAMES],c9_separation_report *report,
 const c9_separation_report *frozen_report);
#endif
#endif
