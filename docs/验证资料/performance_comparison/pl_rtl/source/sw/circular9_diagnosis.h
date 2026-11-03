#ifndef CIRCULAR9_DIAGNOSIS_H
#define CIRCULAR9_DIAGNOSIS_H
#include <stdint.h>

/* Change this ID if orders, rate, window, bands or feature normalization change. */
#define C9_DIAG_FEATURE_CONTRACT 0x43394632u /* C9F2: full-segment decimated envelope */
#define C9_DIAG_FEATURES 18u
/* CPU1-only display copy of the existing envelope FFT; no DSP recomputation. */
void c9_diag_export_envelope(uint16_t bins[128]);
#define C9_DIAG_SAMPLES 40000u
#define C9_DIAG_RATE_NUM 78125u
#define C9_DIAG_RATE_DEN 2u
#define C9_DIAG_CARRIER_LOW_HZ 2200u
#define C9_DIAG_CARRIER_HIGH_HZ 4600u
#define C9_DIAG_CARRIER_TRANSITION_GUARD_HZ 400u
#define C9_DIAG_ORDER_TOLERANCE_FRACTION 0.01
#define C9_DIAG_ORDER_MINIMUM_HALF_WIDTH_HZ 0.9765625
#define C9_DIAG_SEPARATION_CONTRACT 0x43395333u /* C9S3: refined angle, sector soft-null guards */
#define C9_DIAG_MASK_WORDS 7u /* Bits 0..201 are separation FFT bins 8..209. */
#define C9_DIAG_FILTER_VARIANTS 16u
#define C9_DIAG_MODEL_ABI 2u
#define C9_DIAG_BIND_DIRECTION 1u
#define C9_DIAG_BIND_STABLE 2u
#define C9_DIAG_BIND_SEPARATED 4u
#define C9_DIAG_BIND_SNAPSHOT 8u
#define C9_DIAG_BIND_REQUIRED 15u
typedef enum {
 C9_DIAG_UNKNOWN=0, C9_DIAG_NORMAL=1, C9_DIAG_FAULT=2,
 C9_DIAG_INTERFERENCE=3, C9_DIAG_ANOMALY=4
} c9_diag_label;
typedef enum {
 C9_DIAG_OK=0, C9_DIAG_NO_MODEL, C9_DIAG_BAD_MODEL, C9_DIAG_BAD_INPUT,
 C9_DIAG_BAD_BINDING, C9_DIAG_SILENT, C9_DIAG_REJECTED,
 C9_DIAG_UNVALIDATED, C9_DIAG_CLIPPED, C9_DIAG_BAD_FILTER, C9_DIAG_NO_CARRIER
} c9_diag_reason;
typedef struct {
 uint32_t track_id, grid, epoch, first_sample, sample_count, flags;
 int32_t azimuth_mdeg, elevation_mdeg;
 uint32_t separation_contract, usable_mask[C9_DIAG_MASK_WORDS];
} c9_diag_binding;
typedef struct {
 uint32_t abi, feature_contract, version, kind; /* 0:none, 1:normal baseline, 2:3-class */
 uint32_t validated;
 double shaft_hz_min, shaft_hz_max, rms_min;
 double center[3][C9_DIAG_FEATURES]; /* normal, fault, interference */
 double inverse_variance[C9_DIAG_FEATURES];
 double radius[3]; /* mean squared standardized distance, never probability */
 double minimum_margin; /* second / first distance, greater than one */
 double anomaly_multiplier; /* baseline only, >1; anomaly is not a fault */
 uint32_t separation_contract, mask_count;
 uint32_t allowed_masks[C9_DIAG_FILTER_VARIANTS][C9_DIAG_MASK_WORDS];
} c9_diag_model;
typedef struct {
 /* Zero-padding changes bin spacing, never observation resolution. */
 uint32_t status, envelope_samples, fft_size, fft_count, fir_multiplications;
 double observation_seconds, envelope_rate_hz, bin_spacing_hz;
 double hann_enbw_hz, hann_first_null_hz, carrier_rms, modulation_rms;
 double carrier_low_hz, carrier_high_hz, carrier_transition_guard_hz, envelope_lowpass_hz;
} c9_diag_extraction;
#define C9_DIAG_EXTRACT_NOT_RUN 0u
#define C9_DIAG_EXTRACT_OK 1u
#define C9_DIAG_EXTRACT_NO_CARRIER 2u
#define C9_DIAG_EXTRACT_NO_MODULATION 3u
#define C9_DIAG_EXTRACT_BAD_INPUT 4u
typedef struct {
 c9_diag_binding binding;
 uint32_t feature_contract, model_version, model_kind, model_validated;
 uint32_t label, provisional_label, reason, fault_direction_valid, clipped_samples;
 /* Independent six-class experiment; never used as a trusted fault label. */
 uint32_t fstf_available,fstf_class,fstf_version;
 double fstf_distance,fstf_margin;
 double shaft_hz, rms, features[C9_DIAG_FEATURES], distance[3], margin;
 c9_diag_extraction extraction;
} c9_diag_report;

/* The feature extractor has static scratch buffers: call from PS diagnostic core only.
 * Input is separated mono PCM at exactly 39062.5Hz, 40000 samples, normalized +/-1.
 * All candidate reports must retain the matching snapshot/track binding. */
void c9_diagnose(const double audio[C9_DIAG_SAMPLES], double shaft_hz,
 const c9_diag_binding *binding, c9_diag_report *report);
void c9_diagnose_with_model(const double audio[C9_DIAG_SAMPLES], double shaft_hz,
 const c9_diag_binding *binding, const c9_diag_model *model, c9_diag_report *report);
void c9_diag_score_features(const double features[C9_DIAG_FEATURES], double rms,
 double shaft_hz, const c9_diag_binding *binding, const c9_diag_model *model,
 c9_diag_report *report);
const c9_diag_model *c9_diag_configured_model(void);
const char *c9_diag_label_name(uint32_t label);
const char *c9_diag_reason_name(uint32_t reason);
unsigned c9_fstf_experiment_enabled(void);
const char *c9_fstf_class_name(unsigned value);
#endif
