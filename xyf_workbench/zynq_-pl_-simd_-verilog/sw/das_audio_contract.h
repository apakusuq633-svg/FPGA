/* Version 1: PL 8-channel DAS -> PS mono PCM. Wire offsets, not a C struct DMA ABI. */
#ifndef DAS_AUDIO_CONTRACT_H
#define DAS_AUDIO_CONTRACT_H
#include <stdint.h>
#define DAS_AUDIO_MAGIC 0x44415331u
#define DAS_AUDIO_WINDOW 0x700u /* Reserved; absent on existing bitstreams. */
#define DAS_AUDIO_BLOCK 512u
#define DAS_AUDIO_SEGMENT 40000u
#define DAS_AUDIO_FS_NUM 78125u
#define DAS_AUDIO_FS_DEN 2u
#define DAS_AUDIO_INPUT_CHANNELS 8u
#define DAS_FLAG_SYNTHETIC 1u
#define DAS_FLAG_GAP 2u
#define DAS_FLAG_CLIPPED 4u
#define DAS_FLAG_INVALID 8u
#define DAS_FLAG_POSITION_UNKNOWN 16u /* FIFO has no per-sample steering metadata. */
enum das_audio_register {
    DAS_R_MAGIC=0x00, DAS_R_STATUS=0x04, DAS_R_SELECT=0x08,
    DAS_R_SEQ=0x0c, DAS_R_FIRST_LO=0x10, DAS_R_FIRST_HI=0x14,
    DAS_R_LEN=0x18, DAS_R_TARGET=0x1c, DAS_R_GRID_W=0x20,
    DAS_R_STEER_SEQ=0x24, DAS_R_FLAGS=0x28, DAS_R_DROP=0x2c,
    DAS_R_INDEX=0x30, DAS_R_DATA=0x34, DAS_R_ACK_SEQ=0x38,
    DAS_R_RELEASE=0x3c, DAS_R_FS_NUM=0x40, DAS_R_FS_DEN=0x44,
    DAS_R_CHANNELS=0x48
};
typedef struct {
    uint64_t first_sample;
    uint32_t block_seq, sample_count, target_grid, grid_w, steer_seq;
    uint32_t flags, dropped_samples;
} das_block_desc;
typedef struct {
    das_block_desc desc;
    int16_t pcm[DAS_AUDIO_BLOCK];
} das_audio_block;
#endif
