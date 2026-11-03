/* CPU0 owns DMA consumption, GSC, recording UDP and audio publication. */
#ifndef PS_CIRCULAR9_LIVE_H
#define PS_CIRCULAR9_LIVE_H
#include "lwip/udp.h"
#include "circular9_audio.h"
#include "circular9_stream.h"
#include "circular9_deadline.h"
#include "xil_cache.h"
static void c9_record_sample(const uint32_t packet[16]);
static void c9_record_reset(void);
static void c9_record_info(uint32_t info[4]);
#define C9_DMA_BASE 0x43c10000u
static union {uint8_t slots[524288];uint8_t section[1048576];} c9_ddr __attribute__((section(".c9_dma"),aligned(1048576)));
static pdm_stream_ring c9_ring;
static circular9_audio c9_audio;
static struct udp_pcb *c9_udp;
static ip_addr_t c9_peer;
#define C9_AUDIO_BATCH 128u
static uint8_t c9_slots[128*C9_AUDIO_BATCH],c9_packet[48+10*C9_AUDIO_BATCH+4];
static uint32_t c9_sample_number[C9_AUDIO_BATCH];static int16_t c9_fir[C9_AUDIO_BATCH];
static int16_t c9_outputs[C9_AUDIO_BATCH];
static uint16_t c9_reasons[C9_AUDIO_BATCH];
static unsigned c9_batch,c9_requested=0,c9_freeze;
static unsigned sf_audio_allowed;
/* Full-rate raw UDP is opt-in; GUI monitoring must not pay its CRC/network cost. */
static unsigned c9_recording;
/* Explicit nominal-geometry audio experiment; does not certify calibration. */
static unsigned c9_gsc_manual_ready;
static int c9_gsc_target_az,c9_gsc_target_el;

/* Dedicated audio-only /4 path. Raw history and localization stay156250Hz. */
static const int16_t c9_audio_lp[127]={0,0,0,1,2,3,4,5,5,4,3,0,-5,-10,-17,-24,-32,-38,-43,-46,-45,-40,-31,-17,1,24,49,76,102,126,145,158,161,153,132,100,54,-3,-68,-140,-214,-286,-350,-400,-431,-439,-418,-365,-277,-154,4,194,412,653,909,1173,1436,1688,1920,2124,2291,2416,2492,2514,2492,2416,2291,2124,1920,1688,1436,1173,909,653,412,194,4,-154,-277,-365,-418,-439,-431,-400,-350,-286,-214,-140,-68,-3,54,100,132,153,161,158,145,126,102,76,49,24,1,-17,-31,-40,-45,-46,-43,-38,-32,-24,-17,-10,-5,0,3,4,5,5,4,3,2,1,0,0,0};
#include "circular9_audio_fir.h"
static int16_t c9_audio_raw[9][256];static unsigned c9_audio_head,c9_audio_fill,c9_audio_have;
static uint32_t c9_audio_previous,c9_audio_previous_epoch,c9_listen_output_tick;
static int c9_listen_boundary(const uint32_t w[16]);
static int c9_audio_decimate(const uint32_t w[16],int16_t *out){
 if(c9_audio_have&&(w[1]!=c9_audio_previous+1u||w[14]!=c9_audio_previous_epoch)){
  c9_audio_fill=0;c9_audio_head=0;gsc9_config cfg=c9_audio.adaptive.config;
  if(c9_audio.adaptive.configured)gsc9_configure(&c9_audio.adaptive,&cfg);
 }
 c9_audio_previous=w[1];c9_audio_previous_epoch=w[14];c9_audio_have=1;
 for(unsigned ch=0;ch<9;ch++){int16_t v=(int16_t)(w[8+ch/2]>>(16*(ch&1)));c9_audio_raw[ch][c9_audio_head]=v;c9_audio_raw[ch][c9_audio_head+128]=v;}
 if(c9_audio_fill<127)c9_audio_fill++;
 unsigned head=c9_audio_head;c9_audio_head=(head+1)&127u;
 if((w[1]&7u)!=7u||c9_audio_fill<127)return 0;
 if(!c9_listen_boundary(w))return 0;
 uint32_t packet[16]={0};packet[0]=0x47534302;packet[1]=w[1]/8;packet[13]=0x000a0009;packet[14]=w[14];packet[15]=w[15];
 for(unsigned ch=0;ch<9;ch++){
  /* sum(abs(coeff))<65536 proves signed32 accumulation for s16 input. */
  int32_t sum=c9_audio_fir127(c9_audio_raw[ch],head,c9_audio_lp);
  int32_t v=sum>=0?(sum+16384)/32768:-((-sum+16384)/32768);if(v>32767)v=32767;if(v< -32768)v= -32768;
  packet[8+ch/2]|=(uint32_t)(uint16_t)v<<(16*(ch&1));
 }
 *out=gsc9_process_nominal(&c9_audio.adaptive,packet,c9_requested&&c9_gsc_manual_ready&&sf_audio_allowed,c9_freeze);
 c9_audio.reason=gsc9_reason(&c9_audio.adaptive);c9_listen_output_tick=dia_gtimer_now();return 1;
}
static uint32_t c9_profile_count;static uint64_t c9_ring_ticks,c9_history_ticks,c9_output_ticks;
static uint32_t c9_packets,c9_sent,c9_software_drops,c9_last_poll,c9_max_poll_gap,c9_max_service;
static circular9_deadline c9_location;
static uint32_t c9_poll_gap_overruns,c9_service_overruns,c9_dma_backlog_max,c9_network_max_us;
static uint32_t c9_location_poll_gap_max_us,c9_location_poll_overruns;
static uint32_t c9_batch_tick;
#define C9_UDP_QUEUE 16u
typedef struct {
 circular9_metadata metadata;
 uint32_t sample[C9_AUDIO_BATCH];int16_t fir[C9_AUDIO_BATCH];
 int16_t output[C9_AUDIO_BATCH];uint16_t reason[C9_AUDIO_BATCH];unsigned count;
} c9_udp_batch;
static c9_udp_batch c9_udp_queue[C9_UDP_QUEUE];
static uint32_t c9_udp_head,c9_udp_tail,c9_udp_queue_peak;
static uint32_t c9_ticks_to_us(uint32_t ticks){
 return (uint32_t)((uint64_t)ticks*2000000u/XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ);
}
static uint32_t c9_read(void *ctx,uint32_t off){(void)ctx;return Xil_In32(C9_DMA_BASE+off);}
static int c9_write(void *ctx,uint32_t off,uint32_t v){(void)ctx;Xil_Out32(C9_DMA_BASE+off,v);return 0;}
/* One bounded consumer slice owns a producer snapshot and batches ACKs.
 * CRC/owner validation remains per slot. Until flush DMA cannot reuse slots. */
static void c9_barrier(void *ctx);
static unsigned c9_io_slice,c9_io_ack;static uint32_t c9_io_producer,c9_io_consumer;
static uint32_t c9_ring_read(void *ctx,uint32_t off){
 return c9_io_slice&&off==0x14?c9_io_producer:c9_read(ctx,off);
}
static int c9_ring_write(void *ctx,uint32_t off,uint32_t v){
 if(c9_io_slice&&off==0x10){c9_io_consumer=v;c9_io_ack=1;return 0;}
 return c9_write(ctx,off,v);
}
static int c9_io_finish(int rc){
 if(c9_io_ack){c9_barrier(NULL);c9_write(NULL,0x10,c9_io_consumer);}
 c9_io_ack=0;c9_io_slice=0;return rc;
}
/* Dedicated read-only-to-CPU DMA ring, cache-line-aligned128-byte slots.
 * The producer publishes only completed DDR writes. Invalidate every owned
 * slot before copying, and retain ownership/CRC checks before release. */
static uint32_t c9_prefetch_lo,c9_prefetch_hi;
static void c9_invalidate(void *ctx,uint32_t a,size_t n){
 (void)ctx;if(c9_prefetch_hi>c9_prefetch_lo&&a>=c9_prefetch_lo&&(uint64_t)a+n<=c9_prefetch_hi)return;
 Xil_DCacheInvalidateRange((INTPTR)a,(u32)n);
}
static void c9_flush(void *ctx,uint32_t a,size_t n){(void)ctx;Xil_DCacheFlushRange((INTPTR)a,(u32)n);}
static void c9_barrier(void *ctx){(void)ctx;__asm__ volatile("dsb sy":::"memory");}
static const uint8_t *c9_map(void *ctx,uint32_t a,size_t n){
 (void)ctx;uintptr_t lo=(uintptr_t)c9_ddr.slots;
 return a>=lo&&(uint64_t)a+n<=lo+sizeof(c9_ddr.slots)?(const uint8_t *)(uintptr_t)a:NULL;
}
static uint32_t c9_u32(const uint8_t *p){return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static int c9_live_init(void){
 pdm_stream_io io={NULL,c9_ring_read,c9_ring_write,c9_invalidate,c9_flush,c9_barrier,c9_map};
 if(c9_read(NULL,0x48)!=0x000a0009u)return -10;
 Xil_DCacheFlushRange((INTPTR)&c9_ddr,sizeof(c9_ddr));
 Xil_SetTlbAttributes((INTPTR)&c9_ddr,NORM_WB_CACHE);
 circular9_audio_init(&c9_audio);
 c9_audio.target_guard_requested=1;
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
 if(!c9_recording){c9_batch=0;return;}
 if(c9_udp_head-c9_udp_tail==C9_UDP_QUEUE){c9_software_drops+=c9_batch;c9_batch=0;return;}
 c9_udp_batch *b=&c9_udp_queue[c9_udp_head%C9_UDP_QUEUE];
 b->metadata=(circular9_metadata){pdm_ring_stream_id(&c9_ring),c9_packets++,ACOUSTIC_GEOMETRY_VERSION,
  ACOUSTIC_CALIBRATION_VERSION,c9_read(NULL,0x18),c9_software_drops,
  (c9_requested?1u:0u)|((!ACOUSTIC_GEOMETRY_CONFIRMED||!ACOUSTIC_CALIBRATION_VERSION)?2u:0u)};
 b->count=c9_batch;memcpy(b->sample,c9_sample_number,4u*c9_batch);memcpy(b->fir,c9_fir,2u*c9_batch);
 memcpy(b->output,c9_outputs,2u*c9_batch);memcpy(b->reason,c9_reasons,2u*c9_batch);
 c9_batch=0;c9_udp_head++;
 if(c9_udp_head-c9_udp_tail>c9_udp_queue_peak)c9_udp_queue_peak=c9_udp_head-c9_udp_tail;
}
static void c9_send_queued(void){
 c9_udp_batch *b=&c9_udp_queue[c9_udp_tail%C9_UDP_QUEUE];
 /* G9A1: explicit sample IDs, no raw9 payload. 128 frames ->1332 bytes. */
 uint32_t h[12]={0x31413947u,1,b->metadata.session,b->metadata.sequence,156250,8,b->count,b->metadata.geometry_version,b->metadata.calibration_version,b->metadata.dma_drops,b->metadata.software_drops,b->metadata.flags};
 size_t n=48+10u*b->count+4;
 for(unsigned k=0;k<12;k++)for(unsigned j=0;j<4;j++)c9_packet[k*4+j]=(uint8_t)(h[k]>>(j*8));
 for(unsigned k=0;k<b->count;k++){
  uint8_t *p=c9_packet+48+10*k;uint32_t q=b->sample[k];for(unsigned j=0;j<4;j++)p[j]=(uint8_t)(q>>(j*8));
  uint16_t v[3]={(uint16_t)b->fir[k],(uint16_t)b->output[k],b->reason[k]};for(unsigned j=0;j<3;j++){p[4+2*j]=v[j];p[5+2*j]=v[j]>>8;}
 }
 uint32_t crc=pdm_crc32(c9_packet,n-4);for(unsigned j=0;j<4;j++)c9_packet[n-4+j]=(uint8_t)(crc>>(j*8));
 err_t error=ERR_MEM;struct pbuf *p=n&&c9_udp?pbuf_alloc(PBUF_TRANSPORT,(u16_t)n,PBUF_RAM):NULL;
 if(p){if(pbuf_take(p,c9_packet,(u16_t)n)==ERR_OK)error=udp_sendto(c9_udp,p,&c9_peer,1234);pbuf_free(p);}
 if(error==ERR_OK)c9_sent++;else c9_software_drops+=b->count;
 c9_udp_tail++;
}
/* Cooperative budget, not a measured WCET: one lwIP call can exceed it. */
static void c9_network_poll(void){
 if(!c9_recording){c9_udp_tail=c9_udp_head;c9_batch=0;return;}
 uint32_t start=Xil_In32(0xf8f00200u);
 if(c9_batch&&c9_ticks_to_us(start-c9_batch_tick)>=8000u)c9_queue_batch();
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
 uint32_t current_addr=c9_ring.base+((c9_ring.consumer&4095u)*128u);
 /* Invalidate only already-published, still-owned slots, never future DMA data.
  * No ownership release or CRC is skipped. Stop the range at ring wrap. */
 if(backlog&&backlog<=4096u&&!(current_addr>=c9_prefetch_lo&&current_addr+128u<=c9_prefetch_hi)){
  uint32_t at=c9_ring.consumer&4095u,n=backlog<16u?backlog:16u;if(n>4096u-at)n=4096u-at;
  uint32_t addr=c9_ring.base+at*128u;
  c9_barrier(NULL);Xil_DCacheInvalidateRange((INTPTR)addr,n*128u);c9_barrier(NULL);
  c9_prefetch_lo=addr;c9_prefetch_hi=addr+n*128u;
 }
 uint32_t slice_drops=c9_read(NULL,0x18);
 c9_io_producer=c9_read(NULL,0x14);c9_io_ack=0;c9_io_slice=1;
 for(unsigned budget=0;budget<16;budget++) {
  uint8_t *slot=c9_slots+c9_batch*128;uint32_t old_session=pdm_ring_stream_id(&c9_ring);
  unsigned profile=(c9_ring.consumer&255u)==0;uint32_t t0=profile?Xil_In32(0xf8f00200u):0,t1=0,t2=0;
  int rc=pdm_ring_next(&c9_ring,slot);
  if(profile)t1=Xil_In32(0xf8f00200u);
  if(rc==0)break;
  if(rc==-3){c9_record_reset();c9_audio.count=0;c9_audio.filter_count=0;c9_audio.discontinuities++;continue;}
  if(rc<0)return c9_io_finish(-11);
  if(old_session!=pdm_ring_stream_id(&c9_ring)) {
   c9_record_reset();
   /* Do not combine pre-reset samples with the new timestamp epoch. */
   if(c9_batch){memmove(c9_slots,slot,128);c9_software_drops+=c9_batch;c9_batch=0;slot=c9_slots;}
   circular9_audio_init(&c9_audio);c9_audio_have=0;c9_audio_fill=0;
   c9_audio.target_guard_requested=1;
  }
  uint32_t w[16];for(unsigned k=0;k<16;k++)w[k]=c9_u32(slot+4*k);
  c9_record_sample(w);
  if(profile)t2=Xil_In32(0xf8f00200u);
  if(!c9_batch)c9_batch_tick=Xil_In32(0xf8f00200u);
  *drops=slice_drops+w[15];
  /* CPU1 diagnosis consumes the independent raw history. Continuous GSC/FIR
   * output has no consumer while raw UDP recording is disabled; do not run
   * that optional output DSP at156250Hz during monitor-only operation. */
  if(c9_recording){
  complete=0;
  if(!c9_audio_decimate(w,&c9_outputs[c9_batch]))continue;
  }else {complete=0;c9_outputs[c9_batch]=(int16_t)(uint16_t)(w[7]>>16);c9_audio.reason=GSC9_BYPASS_DISABLED;}
  if(profile){uint32_t t3=Xil_In32(0xf8f00200u);c9_profile_count++;c9_ring_ticks+=t1-t0;c9_history_ticks+=t2-t1;c9_output_ticks+=t3-t2;}
  if(complete<0)return c9_io_finish(-12);
  c9_sample_number[c9_batch]=w[1];c9_fir[c9_batch]=c9_audio.nominal_ps?c9_audio.adaptive.model_fir:(int16_t)(w[7]>>16);c9_reasons[c9_batch]=(uint16_t)c9_audio.reason;c9_batch++;
  if(c9_batch==C9_AUDIO_BATCH)c9_queue_batch();
  if(complete){*out=c9_audio.block;break;}
  if((budget&3u)==3u&&c9_ticks_to_us(Xil_In32(0xf8f00200u)-begin)>=75u)break;
 }
 c9_io_finish(0);
 if(c9_read(NULL,0x24)&16u){c9_record_reset();if(pdm_ring_recover(&c9_ring,256))return -13;c9_audio.count=0;}
 uint32_t elapsed=Xil_In32(0xf8f00200u)-begin;if(elapsed>c9_max_service)c9_max_service=elapsed;
 if(c9_ticks_to_us(elapsed)>100u)c9_service_overruns++;
 return complete?DAS_OK:DAS_EMPTY;
}
static int c9_status(char *out,size_t n){
 uint32_t history[4]={0};c9_record_info(history);
 int used=snprintf(out,n,"{\"localizer_abi\":\"P9D2\",\"rv32_itcm_sha256\":\"" ACOUSTIC_ITCM_SHA256 "\","
  "\"pdm_decimation\":16,\"window_samples\":1024,\"capture_slots\":10,\"active_channels\":9,\"active_mask\":511,"
  "\"calibration_status\":\"" ACOUSTIC_CALIBRATION_STATUS "\","
  "\"profile_samples\":%u,\"ring_avg_ticks\":%u,\"history_avg_ticks\":%u,\"output_avg_ticks\":%u,"
  "\"udp_enabled\":%u,\"dma_frame_ok\":%llu,\"dma_corrupt\":%llu,\"history_frames\":%u,\"history_end\":%u,\"history_epoch\":%u,\"history_session\":%u,"
  "\"gsc_requested\":%u,\"freeze_updates\":%u,\"gsc_reason\":%u,"
  "\"gsc_nominal_experiment\":true,\"gsc_audio_rate_num\":156250,\"gsc_audio_rate_den\":8,\"gsc_fixed_target_ready\":%u,\"gsc_target_az_deg\":%d,\"gsc_target_el_deg\":%d,"
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
  "\"histogram_last_bin_includes_overflow\":true,\"tracking_deadline_us\":100000,\"board_validated\":false,\"latency_histogram\":[",(unsigned)c9_profile_count,(unsigned)(c9_profile_count?c9_ring_ticks/c9_profile_count:0),(unsigned)(c9_profile_count?c9_history_ticks/c9_profile_count:0),(unsigned)(c9_profile_count?c9_output_ticks/c9_profile_count:0),c9_recording,(unsigned long long)pdm_ring_stat(&c9_ring,PDM_FRAME_OK),(unsigned long long)pdm_ring_stat(&c9_ring,PDM_CORRUPT),(unsigned)history[1],(unsigned)history[0],(unsigned)history[2],(unsigned)history[3],c9_requested,c9_freeze,(unsigned)c9_audio.reason,
  c9_gsc_manual_ready,c9_gsc_target_az,c9_gsc_target_el,ACOUSTIC_GEOMETRY_CONFIRMED,ACOUSTIC_CALIBRATION_VERSION,ACOUSTIC_GEOMETRY_VERSION,
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
 if(used>=0&&(size_t)used<n)used+=snprintf(out+used,n-(size_t)used,"],\"gsc_active_samples\":%llu,\"gsc_warmup_samples\":%llu,\"gsc_alignment_errors\":%llu,\"gsc_guard_active\":%u}",(unsigned long long)gsc9_stat(&c9_audio.adaptive,GSC9_ACTIVE),(unsigned long long)gsc9_stat(&c9_audio.adaptive,GSC9_WARMUP),(unsigned long long)gsc9_stat(&c9_audio.adaptive,GSC9_ALIGN_ERRORS),(unsigned)gsc9_target_guard_status(&c9_audio.adaptive));
 return used;
}
#endif
