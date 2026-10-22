#ifndef FW_RAW_CAPTURE_H
#define FW_RAW_CAPTURE_H
#include "../raw_capture_protocol.h"
#ifndef FW_RAW_TIMEOUT_CYCLES
#define FW_RAW_TIMEOUT_CYCLES 40000000u
#endif

/* PS may edit CAP INDEX only between READY and RELEASE/CANCEL/timeout. */
static __attribute__((noinline)) void raw_capture_hold(uint32_t request,uint32_t first,uint32_t sequence,
                             unsigned channels)
{
    RESULT(RAW_RESULT_STATE)=RAW_IDLE;
    RESULT(RAW_RESULT_REQUEST)=request;
    RESULT(RAW_RESULT_FIRST)=first;
    RESULT(RAW_RESULT_BANK_SEQ)=sequence;
    RESULT(RAW_RESULT_END_SEQ)=sequence+1;
    RESULT(RAW_RESULT_CHANNELS)=channels;
    RESULT(RAW_RESULT_FRAMES)=RAW_FRAME_COUNT;
    RESULT(RAW_RESULT_FS_NUM)=78125u;RESULT(RAW_RESULT_FS_DEN)=2u;
    RESULT(90)=++loc_seq;RESULT(91)=0;
    RESULT(LOCATION_META16_WORD)=LOCATION_QUALITY_MAGIC;
    RESULT(LOCATION_META16_WORD+1)=32u; /* Explicit calibration pause. */
    RESULT(90)=++loc_seq;
    RESULT(RAW_RESULT_STATE)=RAW_READY;
    uint32_t start=cycles(),id=request&RAW_ID_MASK,command;
    do {
        command=REG(0x4000u,1);
        if(command==(RAW_RELEASE|id))break;
        if(command!=request || cycles()-start>=FW_RAW_TIMEOUT_CYCLES) {
            RESULT(RAW_RESULT_STATE)=RAW_ABORTED;
            return;
        }
    } while(1);
    RESULT(RAW_RESULT_STATE)=RAW_COMPLETE;
}
#endif
