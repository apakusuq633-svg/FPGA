#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#define LOCATION_META16_WORD 96u
#define LOCATION_QUALITY_MAGIC 0x4c515431u
static uint32_t data[128],loc_seq,clock_value,host;
#define RESULT(i) data[i]
#define REG(base,i) host
static uint32_t cycles(void){uint32_t v=clock_value;clock_value+=40000000u;return v;}
#include "fw_raw_capture.h"
int main(void)
{
    host=RAW_RELEASE|7u;clock_value=0;
    raw_capture_hold(RAW_REQUEST|7u,0xfffffc00u,0xffffffffu,12);
    assert(data[RAW_RESULT_STATE]==RAW_COMPLETE&&data[RAW_RESULT_END_SEQ]==0);
    assert(data[91]==0&&data[97]==32&&!(data[90]&1));
    host=RAW_REQUEST|8u;clock_value=0;
    raw_capture_hold(host,123,456,8);
    assert(data[RAW_RESULT_STATE]==RAW_ABORTED);
    host=RAW_RELEASE|9u;clock_value=0;
    raw_capture_hold(RAW_REQUEST|8u,123,456,8);
    assert(data[RAW_RESULT_STATE]==RAW_ABORTED);
    puts("RAW_CAPTURE_FW_PASS exact_release=1 timeout=1 wrong_id=1 sequence_wrap=1 localization_pause=1");
    return 0;
}
