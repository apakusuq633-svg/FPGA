#ifndef C9_SCALAR_H
#define C9_SCALAR_H
#include <stdint.h>
#define C9S_CHANNELS 9
#define C9S_N 1024
#define C9S_BINS 64
#define C9S_PAIRS 36
#define C9S_GRID 1024
#define C9S_LUT_BYTES 46080
typedef struct {
 int16_t time[1024],bins[1026];
 uint32_t spectrum[9*64],statistics[9*5];
 int16_t ring[64];
} c9s_workspace;
/* Input: sample-major, aligned/quantized PCM immediately before the PL
 * localizer. Output arithmetic matches that localizer, not PDM or A9 timing.
 * The raw storage may be reused for corr/scores only after all nine FFTs.
 * lut is the current pair-major Q4 ring delay table packed into ten bits.
 */
void c9s_locate(const int16_t *raw,const uint8_t *lut,const int16_t *hann,
               c9s_workspace *w,int16_t *correlations,int32_t *scores);
#endif
