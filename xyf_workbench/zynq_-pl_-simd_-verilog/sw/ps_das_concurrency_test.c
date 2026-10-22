#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include "ps_das_audio.h"
static das_segment_queue q;
static unsigned done,segments;
static void *producer(void *unused)
{
    unsigned seq,i;das_audio_block b;(void)unused;
    memset(&b,0,sizeof b);b.desc.sample_count=512;b.desc.grid_w=16;
    b.desc.target_grid=53;b.desc.steer_seq=1;
    for(seq=0;seq<2000;seq++) {
        int rc;
        b.desc.block_seq=seq;b.desc.first_sample=(uint64_t)seq*512;
        for(i=0;i<512;i++) b.pcm[i]=(int16_t)((b.desc.first_sample+i)%32768u);
        rc=das_queue_push(&q,&b);assert(rc==DAS_OK || rc==DAS_QUEUE_FULL);
    }
    __atomic_store_n(&done,1u,__ATOMIC_RELEASE);return 0;
}
static void *consumer(void *unused)
{
    (void)unused;
    for(;;) {
        das_segment *s=das_queue_take(&q);unsigned i;
        if(!s) {if(__atomic_load_n(&done,__ATOMIC_ACQUIRE))break;continue;}
        for(i=0;i<DAS_AUDIO_SEGMENT;i++) {
            double expected=(double)((s->desc.first_sample+i)%32768u)/32768.0;
            assert(s->samples[i]==expected);
        }
        segments++;das_queue_release(s);
    }
    return 0;
}
int main(void)
{
    pthread_t p,c;das_queue_init(&q);
    assert(pthread_create(&c,0,consumer,0)==0);
    assert(pthread_create(&p,0,producer,0)==0);
    assert(pthread_join(p,0)==0);assert(pthread_join(c,0)==0);assert(segments>0);
    printf("DAS_CONCURRENCY_PASS segments=%u dropped_samples=%u\n",segments,q.dropped_samples);
    return 0;
}
