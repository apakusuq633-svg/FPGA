#ifndef PDM12_CALIBRATION_H
#define PDM12_CALIBRATION_H
#include <stddef.h>
#include <stdint.h>
#define PDM12_CAL_BYTES 416u
typedef struct {
    uint32_t mic_id;
    int32_t xyz_um[3], delay_q16, gain_q14, dc_offset, polarity;
} pdm12_channel_cal;
typedef struct {
    uint32_t version, flags;
    pdm12_channel_cal channel[12];
} pdm12_calibration;
/* No partial load on error. TEST_ONLY blobs require explicit allow_test=1. */
int pdm12_calibration_load(const uint8_t *blob, size_t length, int allow_test,
                         pdm12_calibration *out);
/* Channel data is signed 24-bit PCM. Delay is represented in LUT generation,
 * relative to channel 0, not silently applied by this scalar amplitude/DC
 * correction function. Load into inactive storage before publishing a new version. */
int32_t pdm12_calibration_correct(const pdm12_calibration *cal, unsigned channel,
                                int32_t sample);
int pdm12_calibration_gain_words(const pdm12_calibration *cal, uint32_t words[6]);
#endif
