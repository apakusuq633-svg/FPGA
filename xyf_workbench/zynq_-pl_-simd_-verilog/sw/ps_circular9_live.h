/* CPU0 owns DMA consumption, GSC, recording UDP and audio publication. */
#ifndef PS_CIRCULAR9_LIVE_H
#define PS_CIRCULAR9_LIVE_H
#include "lwip/udp.h"
#include "circular9_audio.h"
#include "circular9_stream.h"
#include "circular9_deadline.h"
#include "xil_cache.h"
#define C9_DMA_BASE 0x43c10000u
static union {uint8_t slots[524288];uint8_t section[1048576];} c9_ddr __attribute__((section(".c9_dma"),aligned(1048576)));
static pdm_stream_ring c9_ring;
static circular9_audio c9_audio;
static struct udp_pcb *c9_udp;
static ip_addr_t c9_peer;
static uint8_t c9_slots[128*C9_MAX_FRAMES],c9_packet[C9_MAX_PACKET];
static int16_t c9_outputs[C9_MAX_FRAMES];
static uint16_t c9_reasons[C9_MAX_FRAMES];
static unsigned c9_batch,c9_requested=1,c9_freeze;
static uint32_t c9_packets,c9_sent,c9_software_drops,c9_last_poll,c9_max_poll_gap,c9_max_service;
static circular9_deadline c9_location;
static uint32_t c9_poll_gap_overruns,c9_service_overruns,c9_dma_backlog_max,c9_network_max_us;
static uint32_t c9_location_poll_gap_max_us,c9_location_poll_overruns;
static uint32_t c9_batch_tick;
#define C9_UDP_QUEUE 16u
typedef struct {
 circular9_metadata metadata;
 uint8_t slots[128*C9_MAX_FRAMES];
 int16_t output[C9_MAX_FRAMES];uint16_t reason[C9_MAX_FRAMES];unsigned count;
} c9_udp_batch;
static c9_udp_batch c9_udp_queue[C9_UDP_QUEUE];
static uint32_t c9_udp_head,c9_udp_tail,c9_udp_queue_peak;
static uint32_t c9_ticks_to_us(uint32_t ticks){
 return (uint32_t)((uint64_t)ticks*2000000u/XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ);
}
static uint32_t c9_read(void *ctx,uint32_t off){(void)ctx;return Xil_In32(C9_DMA_BASE+off);}
static int c9_write(void *ctx,uint32_t off,uint32_t v){(void)ctx;Xil_Out32(C9_DMA_BASE+off,v);return 0;}
static void c9_cache(void *ctx,uint32_t a,size_t n){(void)ctx;(void)a;(void)n;/* Dedicated noncached section. */}
static void c9_barrier(void *ctx){(void)ctx;__asm__ volatile("dsb sy":::"memory");}
static const uint8_t *c9_map(void *ctx,uint32_t a,size_t n){
 (void)ctx;uintptr_t lo=(uintptr_t)c9_ddr.slots;
 return a>=lo&&(uint64_t)a+n<=lo+sizeof(c9_ddr.slots)?(const uint8_t *)(uintptr_t)a:NULL;
}
static uint32_t c9_u32(const uint8_t *p){return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static int c9_live_init(void){
 pdm_stream_io io={NULL,c9_read,c9_write,c9_cache,c9_cache,c9_barrier,c9_map};
 if(c9_read(NULL,0x48)!=0x000a0009u)return -10;
 Xil_DCacheFlushRange((INTPTR)&c9_ddr,sizeof(c9_ddr));
 Xil_SetTlbAttributes((INTPTR)&c9_ddr,NORM_NONCACHE);
 circular9_audio_init(&c9_audio);
 uint32_t session=Xil_In32(0xf8f00200u);if(!session)session=1;
 return pdm_ring_open(&c9_ring,&io,(uint32_t)(uintptr_t)c9_ddr.slots,12,4000000,
    ACOUSTIC_CALIBRATION_VERSION,0,session,100000);
}
static int c9_network_start(void){
 if(!ipaddr_aton("192.168.2.20",&c9_peer))return -1;
 c9_udp=udp_new();return c9_udp&&udp_bind(c9_udp,IP_ADDR_ANY,1234)==ERR_OK?0:-1;
}
/* Queue only: audio servicing never calls into lwIP or allocates packet memory. */
static void c9_queue_batch(void){
 if(!c9_batch)return;
 if(c9_udp_head-c9_udp_tail==C9_UDP_QUEUE){c9_software_drops+=c9_batch;c9_batch=0;return;}
 c9_udp_batch *b=&c9_udp_queue[c9_udp_head%C9_UDP_QUEUE];
 b->metadata=(circular9_metadata){pdm_ring_stream_id(&c9_ring),c9_packets++,ACOUSTIC_GEOMETRY_VERSION,
  ACOUSTIC_CALIBRATION_VERSION,c9_read(NULL,0x18),c9_software_drops,
  (c9_requested?1u:0u)|((!ACOUSTIC_GEOMETRY_CONFIRMED||!ACOUSTIC_CALIBRATION_VERSION)?2u:0u)};
 b->count=c9_batch;memcpy(b->slots,c9_slots,128u*c9_batch);
 memcpy(b->output,c9_outputs,2u*c9_batch);memcpy(b->reason,c9_reasons,2u*c9_batch);
 c9_batch=0;c9_udp_head++;
 if(c9_udp_head-c9_udp_tail>c9_udp_queue_peak)c9_udp_queue_peak=c9_udp_head-c9_udp_tail;
}
static void c9_send_queued(void){
 c9_udp_batch *b=&c9_udp_queue[c9_udp_tail%C9_UDP_QUEUE];
 size_t n=circular9_encode(&b->metadata,b->slots,b->output,b->reason,b->count,c9_packet,sizeof(c9_packet));
 err_t error=ERR_MEM;struct pbuf *p=n&&c9_udp?pbuf_alloc(PBUF_TRANSPORT,(u16_t)n,PBUF_RAM):NULL;
 if(p){if(pbuf_take(p,c9_packet,(u16_t)n)==ERR_OK)error=udp_sendto(c9_udp,p,&c9_peer,1234);pbuf_free(p);}
 if(error==ERR_OK)c9_sent++;else c9_software_drops+=b->count;
 c9_udp_tail++;
}
/* Cooperative budget, not a measured WCET: one lwIP call can exceed it. */
static void c9_network_poll(void){
 uint32_t start=Xil_In32(0xf8f00200u);
 if(c9_batch&&c9_ticks_to_us(start-c9_batch_tick)>=1000u)c9_queue_batch();
 for(unsigned i=0;i<4u&&c9_udp_tail!=c9_udp_head;i++) {
  c9_send_queued();
  if(c9_ticks_to_us(Xil_In32(0xf8f00200u)-start)>=100u)break;
 }
 uint32_t elapsed=c9_ticks_to_us(Xil_In32(0xf8f00200u)-start);
 if(elapsed>c9_network_max_us)c9_network_max_us=elapsed;
}
/* At most 16 samples or 75 us between returns to location servicing. */
static int c9_live_poll(das_audio_block *out,uint32_t *drops){
 uint32_t begin=Xil_In32(0xf8f00200u);
 if(c9_last_poll&&begin-c9_last_poll>c9_max_poll_gap)c9_max_poll_gap=begin-c9_last_poll;
 if(c9_last_poll&&c9_ticks_to_us(begin-c9_last_poll)>200u)c9_poll_gap_overruns++;
 c9_last_poll=begin;int complete=0;
 uint32_t backlog=c9_read(NULL,0x14)-c9_ring.consumer;
 if(backlog>c9_dma_backlog_max)c9_dma_backlog_max=backlog;
 for(unsigned budget=0;budget<16;budget++) {
  uint8_t *slot=c9_slots+c9_batch*128;uint32_t old_session=pdm_ring_stream_id(&c9_ring);
  int rc=pdm_ring_next(&c9_ring,slot);
  if(rc==0)break;
  if(rc==-3){c9_audio.count=0;c9_audio.filter_count=0;c9_audio.discontinuities++;continue;}
  if(rc<0)return -11;
  if(old_session!=pdm_ring_stream_id(&c9_ring)) {
   /* Do not combine pre-reset samples with the new timestamp epoch. */
   if(c9_batch){memmove(c9_slots,slot,128);c9_software_drops+=c9_batch;c9_batch=0;slot=c9_slots;}
   circular9_audio_init(&c9_audio);
  }
  uint32_t w[16];for(unsigned k=0;k<16;k++)w[k]=c9_u32(slot+4*k);
  if(!c9_batch)c9_batch_tick=Xil_In32(0xf8f00200u);
  *drops=c9_read(NULL,0x18)+w[15];
  complete=circular9_audio_push(&c9_audio,w,acoustic_steer_lut,acoustic_fir_coeff,
    c9_requested&&ACOUSTIC_GEOMETRY_CONFIRMED&&ACOUSTIC_CALIBRATION_VERSION,c9_freeze,*drops,&c9_outputs[c9_batch]);
  if(complete<0)return -12;
  c9_reasons[c9_batch]=(uint16_t)c9_audio.reason;c9_batch++;
  if(c9_batch==C9_MAX_FRAMES)c9_queue_batch();
  if(complete){*out=c9_audio.block;break;}
  if((budget&3u)==3u&&c9_ticks_to_us(Xil_In32(0xf8f00200u)-begin)>=75u)break;
 }
 if(c9_read(NULL,0x24)&16u){if(pdm_ring_recover(&c9_ring,256))return -13;c9_audio.count=0;}
 uint32_t elapsed=Xil_In32(0xf8f00200u)-begin;if(elapsed>c9_max_service)c9_max_service=elapsed;
 if(c9_ticks_to_us(elapsed)>100u)c9_service_overruns++;
 return complete?DAS_OK:DAS_EMPTY;
}
static int c9_status(char *out,size_t n){
 int used=snprintf(out,n,"{\"gsc_requested\":%u,\"freeze_updates\":%u,\"gsc_reason\":%u,"
  "\"geometry_confirmed\":%u,\"calibration_version\":%u,\"geometry_version\":%u,"
  "\"udp_sent\":%u,\"udp_frames_dropped\":%u,\"dma_drops\":%u,\"discontinuities\":%u,"
  "\"max_ps_poll_gap_us\":%u,\"max_ps_service_us\":%u,\"single_window_deadline_us\":%u,"
  "\"pcm_to_ps_us\":%u,\"pcm_to_ps_max_us\":%u,\"deadline_misses\":%u,"
  "\"pcm_to_ps_p95_upper_us\":%u,\"pcm_to_ps_p99_upper_us\":%u,\"latency_samples\":%u,"
  "\"valid_latency_samples\":%u,\"valid_deadline_misses\":%u,\"skipped_publications\":%u,\"clock_errors\":%u,"
  "\"location_stale\":%u,\"stale_after_us\":%u,\"location_poll_target_us\":%u,"
  "\"location_poll_gap_max_us\":%u,\"location_poll_gap_over_200us\":%u,"
  "\"ps_poll_gap_over_200us\":%u,\"ps_service_over_100us\":%u,\"dma_backlog_max\":%u,"
  "\"udp_queue_peak\":%u,\"udp_service_max_us\":%u,\"sample_rate_num\":%u,\"sample_rate_den\":%u,\"hop_samples\":%u,"
  "\"latency_scope\":\"first_pcm_to_first_ps_metadata_receipt\",\"latency_bin_us\":%u,"
  "\"histogram_last_bin_includes_overflow\":true,\"tracking_deadline_us\":100000,\"board_validated\":false,\"latency_histogram\":[",c9_requested,c9_freeze,(unsigned)c9_audio.reason,
  ACOUSTIC_GEOMETRY_CONFIRMED,ACOUSTIC_CALIBRATION_VERSION,ACOUSTIC_GEOMETRY_VERSION,
  (unsigned)c9_sent,(unsigned)c9_software_drops,(unsigned)c9_read(NULL,0x18),(unsigned)c9_audio.discontinuities,
  (unsigned)c9_ticks_to_us(c9_max_poll_gap),(unsigned)c9_ticks_to_us(c9_max_service),C9_LOCATION_TARGET_US,
  (unsigned)c9_location.last_us,(unsigned)c9_location.max_us,(unsigned)c9_location.misses,
  (unsigned)c9_deadline_percentile_upper(&c9_location,95),(unsigned)c9_deadline_percentile_upper(&c9_location,99),
  (unsigned)c9_location.samples,(unsigned)c9_location.valid_samples,(unsigned)c9_location.valid_misses,
  (unsigned)c9_location.skipped_publications,(unsigned)c9_location.clock_errors,(unsigned)c9_location.stale,
  (unsigned)C9_STALE_AFTER_US,C9_LOCATION_POLL_US,(unsigned)c9_location_poll_gap_max_us,(unsigned)c9_location_poll_overruns,
  (unsigned)c9_poll_gap_overruns,(unsigned)c9_service_overruns,
  (unsigned)c9_dma_backlog_max,(unsigned)c9_udp_queue_peak,(unsigned)c9_network_max_us,
  ACOUSTIC_SAMPLE_RATE_NUM,ACOUSTIC_SAMPLE_RATE_DEN,ACOUSTIC_LOCALIZER_HOP,C9_LATENCY_BIN_US);
 for(unsigned i=0;i<C9_LATENCY_BINS&&used>=0&&(size_t)used<n;i++)
  used+=snprintf(out+used,n-(size_t)used,"%s%u",i?",":"",(unsigned)c9_location.histogram[i]);
 if(used>=0&&(size_t)used<n)used+=snprintf(out+used,n-(size_t)used,"]}");
 return used;
}
#endif
