#ifndef PDM_STREAM_H
#define PDM_STREAM_H
#include <stddef.h>
#include <stdint.h>
#define PDM_SLOT_BYTES 128u
#define PDM_UDP_HEADER_BYTES 48u
#define PDM_UDP_MAX_FRAMES 8u
#define PDM_UDP_MAX_BYTES (48u+132u*8u+4u)
enum {PDM_FRAME_OK,PDM_CORRUPT,PDM_OWNER_ERRORS,PDM_IO_ERRORS,PDM_POLL_TIMEOUTS,
      PDM_DUPLICATES,PDM_OUT_OF_ORDER,PDM_SAMPLE_GAPS,PDM_SOURCE_RESTARTS,
      PDM_TIMESTAMP_ROLLBACKS,PDM_RECOVERIES,PDM_STREAM_STATS};
typedef struct {
 void *context;
 uint32_t (*read_reg)(void *,uint32_t offset);
 int (*write_reg)(void *,uint32_t offset,uint32_t value);
 void (*invalidate)(void *,uint32_t address,size_t length);
 void (*flush)(void *,uint32_t address,size_t length);
 void (*barrier)(void *);
 const uint8_t *(*map)(void *,uint32_t address,size_t length);
} pdm_stream_io;
typedef struct {
 pdm_stream_io io;
 uint32_t base,slots_log2,consumer,calibration_version,stream_id,opened,have_sample,last_sample;
 uint64_t last_timestamp,stats[PDM_STREAM_STATS];
} pdm_stream_ring;
typedef struct {
 uint32_t stream_id,packet_sequence,calibration_version,dma_drops;
 uint16_t flags; /* bit0 GSC requested, bit1 RAW present, bit2 unverified,
                  * bit3 source restart, bit4 saturating counters reached max */
} pdm_udp_metadata;
size_t pdm_stream_ring_size(void);
/* Does not seize an already-owned ring: returns busy if published slots remain.
 * The supplied DDR region is dedicated, 128-byte aligned and below 256MiB. */
int pdm_ring_open(pdm_stream_ring *,const pdm_stream_io *,uint32_t base,unsigned slots_log2,
                  uint32_t timeout_cycles,uint32_t calibration_version,uint32_t initial_counter,
                  uint32_t stream_id,unsigned poll_limit);
/* 1 copied/validated frame; 0 empty; -3 corrupt frame released and counted;
 * other negatives are ownership/I/O errors. Never returns an owned DDR pointer. */
int pdm_ring_next(pdm_stream_ring *,uint8_t slot[PDM_SLOT_BYTES]);
/* Quiesce and drain the outstanding AXI transaction before clearing fault.
 * Published ownership remains intact; queued discards are counted by PL. */
int pdm_ring_recover(pdm_stream_ring *,unsigned poll_limit);
uint64_t pdm_ring_stat(const pdm_stream_ring *,unsigned);
uint32_t pdm_ring_stream_id(const pdm_stream_ring *);
uint32_t pdm_crc32(const uint8_t *,size_t);
int pdm_slot_validate(const uint8_t slot[128],uint32_t expected_owner);
/* Returns total UDP bytes, or 0 for invalid input/capacity. No socket calls. */
size_t pdm_udp_encode(const pdm_udp_metadata *,const uint8_t *slots,const int16_t *gsc,
                     const uint16_t *reasons,unsigned frames,uint8_t *out,size_t capacity);
#endif
