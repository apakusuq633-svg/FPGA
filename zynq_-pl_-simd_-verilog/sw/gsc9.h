#ifndef GSC9_H
#define GSC9_H
#include <stddef.h>
#include <stdint.h>
enum {GSC9_PACKETS,GSC9_ACTIVE,GSC9_DISABLED,GSC9_WARMUP,GSC9_BAD_FORMAT,
 GSC9_SEQ_ERRORS,GSC9_LOST_PACKETS,GSC9_OVERFLOW_EVENTS,GSC9_META_MISMATCH,
 GSC9_TRANSITIONS,GSC9_ALIGN_ERRORS,GSC9_SATURATIONS,GSC9_COEFF_CLIPS,
 GSC9_UPDATE_FROZEN,GSC9_DIVERGENCE,GSC9_RESTARTS,GSC9_REF_CLIPS,GSC9_INPUT_CLIPS,GSC9_STATS};
enum {GSC9_OK=0,GSC9_BYPASS_DISABLED=1,GSC9_BYPASS_WARMUP=2,GSC9_BYPASS_FORMAT=3,
 GSC9_BYPASS_SEQUENCE=4,GSC9_BYPASS_METADATA=5,GSC9_BYPASS_TRANSITION=6,
 GSC9_BYPASS_ALIGNMENT=7,GSC9_BYPASS_DIVERGENCE=8,GSC9_BYPASS_UNCONFIGURED=9};
typedef struct {
 uint32_t version,epoch;
 uint16_t direction_id,mu_q15;
 uint32_t epsilon,delay_q16[9];
 int16_t fir_q15[32];
} gsc9_config;
typedef struct {
 gsc9_config config;
 uint32_t configured,have_packet,last_seq,last_overflow,enabled_prev;
 uint32_t head,fhead,length,stable,last_reason;
 int16_t raw[9][64],blocking_fir[8][32],beam_fir[32];
 int32_t integrator[8],weight[8][4];
 int16_t reference_history[8][16],model_das,model_fir;
 uint64_t stats[GSC9_STATS];
} gsc9_state;
size_t gsc9_state_size(void);
void gsc9_reset(gsc9_state *s);
/* Validate into inactive configuration; resets signal history, retains counters. */
int gsc9_configure(gsc9_state *s,const gsc9_config *config);
/* One circular9 gsc_tap v2 packet -> one output bearing the same sample_seq.
 * Word values must already be decoded from little endian. enabled defaults to 0
 * in the caller; transition/mismatch/loss automatically returns original FIR. */
int16_t gsc9_process(gsc9_state *s,const uint32_t words[16],int enabled,int freeze_updates);
uint64_t gsc9_stat(const gsc9_state *s,unsigned index);
uint32_t gsc9_reason(const gsc9_state *s);
uint32_t gsc9_model_beam(const gsc9_state *s);
void gsc9_get_weights(const gsc9_state *s,int32_t weights[32]);
#ifdef GSC9_TEST
void gsc9_test_corrupt_weights(gsc9_state *s);
void gsc9_test_weight(gsc9_state *s,unsigned index,int32_t value);
#endif
#endif
