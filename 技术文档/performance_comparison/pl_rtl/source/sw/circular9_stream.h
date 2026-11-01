#ifndef CIRCULAR9_STREAM_H
#define CIRCULAR9_STREAM_H
#include "pdm_stream.h"
#define C9_HEADER_BYTES 64u
#define C9_FRAME_BYTES 132u
#define C9_MAX_FRAMES 8u
#define C9_MAX_PACKET (C9_HEADER_BYTES+C9_MAX_FRAMES*C9_FRAME_BYTES+4u)
typedef struct {
 uint32_t session,sequence,geometry_version,calibration_version,dma_drops,software_drops;
 uint32_t flags; /* bit0 adaptive requested; bit1 geometry/calibration unverified */
} circular9_metadata;
size_t circular9_encode(const circular9_metadata *,const uint8_t *slots,
 const int16_t *output,const uint16_t *reason,unsigned n,uint8_t *packet,size_t capacity);
#endif
