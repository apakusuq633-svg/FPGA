#ifndef RAW9_RECORD_H
#define RAW9_RECORD_H
#include <stdint.h>
#include <stddef.h>
#define RAW9_FRAMES 3840000u
#define RAW9_BYTES 69120000u
/* sink: 1 accepted, 0 temporary backpressure, -1 permanent I/O error.
 * caller must keep draining DMA. Queue full is fatal, never gap-fill. */
typedef int (*raw9_sink)(void*,const uint8_t*,size_t);
typedef struct {
 uint32_t frames,next_sample,start_sample,drops_base,tap_base;
 uint32_t overflow_count,gap_count,write_errors;uint64_t first_clock,last_clock;
 unsigned started,failed,complete;size_t used;
 uint8_t block[18*1024];raw9_sink sink;void *context;
} raw9_record;
void raw9_init(raw9_record*,raw9_sink,void*);
int raw9_feed(raw9_record*,const uint8_t slot[128]);
int raw9_flush(raw9_record*);
#endif
