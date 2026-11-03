#ifndef PS_DAS_REPORT_H
#define PS_DAS_REPORT_H
#include "das_audio_contract.h"
#define DAS_PLOT_N 128u
typedef struct {
    das_block_desc desc;
    uint32_t valid, shaft_millihz;
    int32_t mean_ppm;
    uint32_t rms_ppm,peak_ppm,clipped_samples,spectrum_dc_ppm;
    uint32_t envelope[DAS_PLOT_N]; /* first 128 bins, df=39062.5/8192 Hz */
    uint32_t spectrum[DAS_PLOT_N]; /* max per 32-bin group, single 8192-point Hann window */
} das_audio_report;
#endif
