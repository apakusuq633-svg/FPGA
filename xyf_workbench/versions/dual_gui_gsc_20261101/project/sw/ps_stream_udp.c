/* Standalone Cortex-A9 / lwIP RAW UDP. Attaches to a running matching PL;
 * never resets/programs the PL, RV32, PDM or either CPU. See M9 report. */
#include <stdint.h>
#include <stddef.h>
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xil_exception.h"
#include "xscugic.h"
#include "xemacps.h"
#include "lwip/init.h"
#include "lwip/udp.h"
#include "lwip/etharp.h"
#include "netif/xadapter.h"
#include "netif/xemacpsif.h"
#include "pdm_stream.h"
#include "gsc12.h"
#include "pdm12_calibration.h"
#ifdef PDM_GSC_PROFILE
#include "pdm_profile.h"
#endif
#ifndef PDM_ENABLE_GSC
#define PDM_ENABLE_GSC 0
#endif
#ifndef PDM_BOARD_IP
#define PDM_BOARD_IP "192.168.2.10"
#endif
#ifndef PDM_PEER_IP
#define PDM_PEER_IP "192.168.2.20"
#endif
#define DMA_BASE 0x43c10000u
#define GT_BASE 0xf8f00200u
extern uint8_t __dma_ring_start[],__dma_ring_end[];
static struct netif nic;
static XScuGic gic;
static pdm_stream_ring ring;
static gsc12_state gsc;
static uint8_t incoming[128],slots[4*128],datagram[PDM_UDP_MAX_BYTES];
static int16_t outputs[4];
static uint16_t reasons[4];
static uint32_t attempted,sent,discarded_frames,encode_errors,recover_failures;
static uint32_t calibration_version,profile_ready;
static void add_count(uint32_t *p,uint32_t n){if(UINT32_MAX-*p<n)*p=UINT32_MAX;else *p+=n;}
static uint32_t rd(void *c,uint32_t off){(void)c;return Xil_In32(DMA_BASE+off);}
static int wr(void *c,uint32_t off,uint32_t v){(void)c;Xil_Out32(DMA_BASE+off,v);return 0;}
static void invalidate(void *c,uint32_t a,size_t n){(void)c;Xil_DCacheInvalidateRange(a,n);}
static void flush(void *c,uint32_t a,size_t n){(void)c;Xil_DCacheFlushRange(a,n);}
static void barrier(void *c){(void)c;
#ifdef PDM_STREAM_HOST_TEST
 __sync_synchronize();
#else
 __asm__ volatile("dsb sy":::"memory");
#endif
}
static const uint8_t *map(void *c,uint32_t a,size_t n){
 (void)c;uintptr_t lo=(uintptr_t)__dma_ring_start,hi=(uintptr_t)__dma_ring_end;
 if(a<lo||(uint64_t)a+n>hi)return NULL;
 return (const uint8_t *)(uintptr_t)a;
}
static uint32_t le32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static uint64_t ticks(void){uint32_t hi,lo,next;do{hi=Xil_In32(GT_BASE+4);lo=Xil_In32(GT_BASE);next=Xil_In32(GT_BASE+4);}while(hi!=next);return (uint64_t)hi<<32|lo;}
static int interrupts(void){
 XScuGic_Config *cfg=XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);
 struct xemac_s *x=(struct xemac_s *)nic.state;
 xemacpsif_s *e=(xemacpsif_s *)x->state;
 if(!cfg||XScuGic_CfgInitialize(&gic,cfg,cfg->CpuBaseAddress)!=XST_SUCCESS)return -1;
 Xil_ExceptionInit();
 Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,(Xil_ExceptionHandler)XScuGic_InterruptHandler,&gic);
 if(XScuGic_Connect(&gic,XPAR_XEMACPS_0_INTR,(Xil_ExceptionHandler)XEmacPs_IntrHandler,&e->emacps)!=XST_SUCCESS)return -1;
 XScuGic_Enable(&gic,XPAR_XEMACPS_0_INTR);Xil_ExceptionEnable();return 0;
}
static int profile_init(void){
 gsc12_reset(&gsc);
#ifdef PDM_GSC_PROFILE
 pdm12_calibration cal;
 if(pdm12_calibration_load(pdm_profile_blob,sizeof pdm_profile_blob,PDM_PROFILE_TEST,&cal)||
    pdm_crc32((const uint8_t *)pdm_profile_delays,sizeof pdm_profile_delays)!=PDM_PROFILE_TABLE_CRC)return -1;
 calibration_version=cal.version;profile_ready=1;
#endif
 return 0;
}
static int16_t process(const uint8_t *slot,uint16_t *reason){
 uint32_t words[16];for(unsigned i=0;i<16;i++)words[i]=le32(slot+4*i);
#ifdef PDM_GSC_PROFILE
 unsigned direction=(words[6]>>8)&1023u;
 if(profile_ready&&PDM_ENABLE_GSC&&(words[6]&3u)==1u&&
    (!gsc.configured||gsc.config.version!=words[2]||gsc.config.epoch!=words[14]||gsc.config.direction_id!=direction)){
  gsc12_config c={0};c.version=words[2];c.epoch=words[14];c.direction_id=(uint16_t)direction;c.mu_q15=8192;c.epsilon=1u<<20;
  for(unsigned i=0;i<12;i++)c.delay_q16[i]=pdm_profile_delays[direction][i];
  for(unsigned i=0;i<32;i++)c.fir_q15[i]=pdm_profile_fir[i];
  if(gsc12_configure(&gsc,&c))profile_ready=0;
 }
#endif
 int16_t out=gsc12_process(&gsc,words,PDM_ENABLE_GSC&&profile_ready,0);
 *reason=(uint16_t)gsc12_reason(&gsc);return out;
}
int main(void){
 ip_addr_t ip,mask,gateway,peer;unsigned char mac[6]={2,0,0,0,0x12,9};
 pdm_stream_io io={NULL,rd,wr,invalidate,flush,barrier,map};
 xil_printf("PDM9 UDP: requires matching already-running PL; no PL reset/start performed\r\n");
 if((uintptr_t)__dma_ring_start!=0x08000000u||(uintptr_t)__dma_ring_end-(uintptr_t)__dma_ring_start!=0x80000||profile_init())return 1;
 lwip_init();
 if(!ipaddr_aton(PDM_BOARD_IP,&ip)||!ipaddr_aton("255.255.255.0",&mask)||
    !ipaddr_aton("0.0.0.0",&gateway)||!ipaddr_aton(PDM_PEER_IP,&peer))return 2;
 if(!xemac_add(&nic,&ip,&mask,&gateway,mac,XPAR_XEMACPS_0_BASEADDR))return 3;
 netif_set_default(&nic);netif_set_up(&nic);if(interrupts())return 4;
 struct udp_pcb *pcb=udp_new();if(!pcb||udp_bind(pcb,IP_ADDR_ANY,1234)!=ERR_OK)return 5;
 /* Enable only the free-running PS global timer. No acoustic/control reset. */
 Xil_Out32(GT_BASE+8,Xil_In32(GT_BASE+8)|1u);
 uint32_t session=(uint32_t)ticks();if(!session)session=1;
 if(pdm_ring_open(&ring,&io,(uint32_t)(uintptr_t)__dma_ring_start,12,4000000,
                  calibration_version,0,session,100000)){xil_printf("PDM9 ring busy/unavailable; ownership preserved\r\n");return 6;}
 uint64_t next=ticks(),last_recover=next;
 const uint64_t second=XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ/2u;
 uint64_t stats_due=next+second,batch_start=next;uint32_t batch_session=session;unsigned count=0;
 for(;;){
  xemacif_input(&nic);uint64_t now=ticks();
  if(now-next>=second){etharp_tmr();eth_link_detect(&nic);next=now;}
  int result=pdm_ring_next(&ring,incoming);
  if(result==1){
   uint32_t current=pdm_ring_stream_id(&ring);
   if(current!=batch_session){add_count(&discarded_frames,count);count=0;}
   if(!count)batch_start=now;
   for(unsigned i=0;i<128;i++)slots[128*count+i]=incoming[i];
   outputs[count]=process(slots+128*count,&reasons[count]);batch_session=current;count++;
  }
  if(count&&(count==4||now-batch_start>=second/1000u)){
   uint32_t status=rd(NULL,0x24);
   pdm_udp_metadata m={batch_session,attempted++,calibration_version,rd(NULL,0x18),
      /* This application has no board acceptance record; keep UNVERIFIED set
       * even when a nonzero calibration version/profile is supplied. */
      (uint16_t)(6u|(profile_ready&&PDM_ENABLE_GSC?1u:0u)|((status&256u)?16u:0u))};
   size_t n=pdm_udp_encode(&m,slots,outputs,reasons,count,datagram,sizeof datagram);
   err_t error=ERR_MEM;struct pbuf *p=n?pbuf_alloc(PBUF_TRANSPORT,(u16_t)n,PBUF_RAM):NULL;
   if(!n)add_count(&encode_errors,1);
   if(p){if(pbuf_take(p,datagram,(u16_t)n)==ERR_OK)error=udp_sendto(pcb,p,&peer,1234);pbuf_free(p);}
   if(error==ERR_OK)add_count(&sent,1);else add_count(&discarded_frames,count);
   count=0;
  }
  if((rd(NULL,0x24)&16u)&&now-last_recover>=second/10u){
   if(pdm_ring_recover(&ring,256))add_count(&recover_failures,1);
   last_recover=now;
  }
  if(now>=stats_due){
   xil_printf("PDM9 attempts=%u sent=%u software_discard=%u invalid=%u DMA_drop=%u fault=%u recover_wait=%u frames=%u\r\n",
    attempted,sent,discarded_frames,encode_errors,rd(NULL,0x18),rd(NULL,0x38),recover_failures,(uint32_t)pdm_ring_stat(&ring,PDM_FRAME_OK));
   stats_due=now+second;
  }
 }
}
