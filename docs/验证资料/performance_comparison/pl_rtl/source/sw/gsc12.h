#ifndef GSC12_H
#define GSC12_H
#include <stddef.h>
#include <stdint.h>
enum {GSC12_PACKETS,GSC12_ACTIVE,GSC12_DISABLED,GSC12_WARMUP,GSC12_BAD_FORMAT,
 GSC12_SEQ_ERRORS,GSC12_LOST_PACKETS,GSC12_OVERFLOW_EVENTS,GSC12_META_MISMATCH,
 GSC12_TRANSITIONS,GSC12_ALIGN_ERRORS,GSC12_SATURATIONS,GSC12_COEFF_CLIPS,
 GSC12_UPDATE_FROZEN,GSC12_DIVERGENCE,GSC12_RESTARTS,GSC12_REF_CLIPS,GSC12_INPUT_CLIPS,GSC12_STATS};
enum {GSC12_OK=0,GSC12_BYPASS_DISABLED=1,GSC12_BYPASS_WARMUP=2,GSC12_BYPASS_FORMAT=3,
 GSC12_BYPASS_SEQUENCE=4,GSC12_BYPASS_METADATA=5,GSC12_BYPASS_TRANSITION=6,
 GSC12_BYPASS_ALIGNMENT=7,GSC12_BYPASS_DIVERGENCE=8,GSC12_BYPASS_UNCONFIGURED=9};
typedef struct {
 uint32_t version,epoch;
 uint16_t direction_id,mu_q15;
 uint32_t epsilon,delay_q16[12];
 int16_t fir_q15[32];
} gsc12_config;
typedef struct {
 gsc12_config config;
 uint32_t configured,have_packet,last_seq,last_overflow,enabled_prev;
 uint32_t head,fhead,length,stable,last_reason;
 int16_t raw[12][64],blocking_fir[11][32],beam_fir[32];
 int32_t integrator[11],weight[11][4];
 int16_t reference_history[11][4],model_das,model_fir;
 uint64_t stats[GSC12_STATS];
} gsc12_state;
size_t gsc12_state_size(void);
void gsc12_reset(gsc12_state *s);
/* Validate into inactive configuration; resets signal history, retains counters. */
int gsc12_configure(gsc12_state *s,const gsc12_config *config);
/* One gsc_tap v1 packet -> one output bearing the same sample_seq.
 * Word values must already be decoded from little endian. enabled defaults to 0
 * in the caller; transition/mismatch/loss automatically returns original FIR. */
int16_t gsc12_process(gsc12_state *s,const uint32_t words[16],int enabled,int freeze_updates);
uint64_t gsc12_stat(const gsc12_state *s,unsigned index);
uint32_t gsc12_reason(const gsc12_state *s);
uint32_t gsc12_model_beam(const gsc12_state *s);
void gsc12_get_weights(const gsc12_state *s,int32_t weights[44]);
#ifdef GSC12_TEST
void gsc12_test_corrupt_weights(gsc12_state *s);
void gsc12_test_weight(gsc12_state *s,unsigned index,int32_t value);
#endif
#endif
