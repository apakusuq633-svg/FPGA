#include <stdint.h>
#include <string.h>
#include "xparameters.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xscugic.h"
#include "xemacps.h"
#include "lwip/init.h"
#include "lwip/udp.h"
#include "lwip/sys.h"
#include "lwip/etharp.h"
#include "netif/xadapter.h"
#include "netif/xemacpsif.h"
#include "pdm_stream.h"
#include "raw9_record.h"
#include "raw9_tx.h"
static raw9_tx tx;static uint32_t tx_tick;static int tx_error;
static uint32_t tx_alloc_failures,tx_reclaimed,tx_free;
#define C9_DMA_BASE 0x43c10000u
#define CTRL 0x41200000u
static struct netif server_netif;
static union {uint8_t slots[524288];uint8_t section[1048576];} c9_ddr __attribute__((section(".c9_dma"),aligned(1048576)));
static pdm_stream_ring ring;static raw9_record rec;
static struct udp_pcb *udp;static ip_addr_t peer;static u16_t peer_port;
static unsigned run,finish_pending,session,packet;
static uint32_t sequence_base;static uint64_t capture_clock;static uint32_t last_progress;
static uint8_t wire[44+1152];
static void put(uint8_t*p,uint32_t n){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(n>>(i*8));}
static uint32_t timer(void){return Xil_In32(0xf8f00200u);}
static uint32_t c9_read(void *ctx,uint32_t off){(void)ctx;return Xil_In32(C9_DMA_BASE+off);}
static int c9_write(void *ctx,uint32_t off,uint32_t v){(void)ctx;Xil_Out32(C9_DMA_BASE+off,v);return 0;}
/* Dedicated read-only-to-CPU DMA ring, cache-line-aligned128-byte slots.
 * The producer publishes only completed DDR writes. Invalidate every owned
 * slot before copying, and retain ownership/CRC checks before release. */
static void c9_invalidate(void *ctx,uint32_t a,size_t n){(void)ctx;Xil_DCacheInvalidateRange((INTPTR)a,(u32)n);}
static void c9_flush(void *ctx,uint32_t a,size_t n){(void)ctx;Xil_DCacheFlushRange((INTPTR)a,(u32)n);}
static void c9_barrier(void *ctx){(void)ctx;__asm__ volatile("dsb sy":::"memory");}
static const uint8_t *c9_map(void *ctx,uint32_t a,size_t n){
 (void)ctx;uintptr_t lo=(uintptr_t)c9_ddr.slots;
 return a>=lo&&(uint64_t)a+n<=lo+sizeof(c9_ddr.slots)?(const uint8_t *)(uintptr_t)a:NULL;
}
static __attribute__((unused)) uint32_t c9_u32(const uint8_t *p){return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static XScuGic gic;

static int gic_setup(void)
{
    XScuGic_Config *cfg;
    struct xemac_s *xemac;
    xemacpsif_s *xemacpsif;
    s32_t st;

    xemac     = (struct xemac_s *)server_netif.state;
    xemacpsif = (xemacpsif_s *)xemac->state;

    cfg = XScuGic_LookupConfig(XPAR_SCUGIC_0_DEVICE_ID);
    if (cfg == NULL) {
        return XST_FAILURE;
    }
    st = XScuGic_CfgInitialize(&gic, cfg, cfg->CpuBaseAddress);
    if (st != XST_SUCCESS) {
        return st;
    }

    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
                                 (Xil_ExceptionHandler)XScuGic_InterruptHandler, &gic);

    st = XScuGic_Connect(&gic, XPAR_XEMACPS_0_INTR,
                         (Xil_ExceptionHandler)XEmacPs_IntrHandler,
                         (void *)&xemacpsif->emacps);
    if (st != XST_SUCCESS) {
        return st;
    }
    XScuGic_Enable(&gic, XPAR_XEMACPS_0_INTR);
    return XST_SUCCESS;
}


/* Reap only descriptors that GEM marks complete. Same driver routine as
 * low_level_output, serialized against its completion interrupt. This must
 * precede pbuf_alloc so heap pressure cannot bypass the reclamation path. */
static void reclaim_completed_tx(void){
 struct xemac_s *em=(struct xemac_s*)server_netif.state;
 xemacpsif_s *ps=(xemacpsif_s*)em->state;
 XEmacPs_BdRing *ring=&XEmacPs_GetTxRing(&ps->emacps);
 SYS_ARCH_DECL_PROTECT(level);
 SYS_ARCH_PROTECT(level);
 uint32_t before=XEmacPs_BdRingGetFreeCnt(ring);
 process_sent_bds(ps,ring);
 tx_free=XEmacPs_BdRingGetFreeCnt(ring);
 if(tx_free>before)tx_reclaimed+=tx_free-before;
 SYS_ARCH_UNPROTECT(level);
}
/* One datagram <=1196 bytes, no IP fragmentation on a normal1500 MTU.
 * No hidden retries/gap filling. PC verifies both sequence and final status. */
static int send_packet(unsigned kind,uint32_t first,unsigned frames,const uint8_t *pcm){
 unsigned size=kind==2?112:44+18*frames;memset(wire,0,44);
 put(wire,0x52393132u);put(wire+4,session);put(wire+8,kind);put(wire+12,packet);
 put(wire+16,first);put(wire+20,frames);put(wire+24,rec.frames);
 put(wire+28,rec.failed);put(wire+32,rec.overflow_count);put(wire+36,rec.gap_count);
 if(frames)memcpy(wire+44,pcm,18*frames);
 if(kind==2){put(wire+44,rec.start_sample);put(wire+48,(uint32_t)rec.first_clock);put(wire+52,(uint32_t)(rec.first_clock>>32));
 put(wire+56,(uint32_t)rec.last_clock);put(wire+60,(uint32_t)(rec.last_clock>>32));
 put(wire+64,c9_read(0,0x18));put(wire+68,c9_read(0,0x1c));put(wire+72,c9_read(0,0x20));put(wire+76,rec.write_errors);put(wire+80,tx.retries);put(wire+84,tx.peak);put(wire+88,tx.sent);put(wire+92,(uint32_t)tx_error);put(wire+96,tx.full);put(wire+100,tx_alloc_failures);put(wire+104,tx_reclaimed);put(wire+108,tx_free);}
 put(wire+40,pdm_crc32(wire,size));
 reclaim_completed_tx();
 struct pbuf *b=pbuf_alloc(PBUF_TRANSPORT,size,PBUF_RAM);if(!b){tx_alloc_failures++;tx_error=ERR_MEM;return 0;}
 err_t e=pbuf_take(b,wire,size);if(e==ERR_OK)e=udp_sendto(udp,b,&peer,peer_port);pbuf_free(b);
 if(e==ERR_OK){packet++;return 1;}tx_error=(int)e;return 0;
}
static int tx_send(void*ctx,uint32_t first,unsigned frames,const uint8_t*pcm){
 (void)ctx;return send_packet(1,first,frames,pcm);
}
static int sink(void*ctx,const uint8_t*data,size_t n){
 (void)ctx;return raw9_tx_push(&tx,rec.frames-(uint32_t)(n/18),data,n)==1?1:-1;
}
static void receive(void*arg,struct udp_pcb*u,struct pbuf*b,const ip_addr_t*a,u16_t port){
 (void)arg;(void)u;char cmd[8]={0};if(!b)return;
 if(b->tot_len<sizeof(cmd))pbuf_copy_partial(b,cmd,b->tot_len,0);
 pbuf_free(b);
 if(!strcmp(cmd,"STOP")&&run){rec.failed=1;run=0;Xil_Out32(CTRL,0);finish_pending=20;}
 if(strcmp(cmd,"START")||run||finish_pending)return;
 peer=*a;peer_port=port;session=timer();if(!session)session=1;packet=0;
 memset(&tx,0,sizeof(tx));tx_tick=timer();tx_error=0;tx_alloc_failures=tx_reclaimed=tx_free=0;raw9_init(&rec,sink,0);pdm_stream_io bus={0,c9_read,c9_write,c9_invalidate,c9_flush,c9_barrier,c9_map};
 Xil_Out32(CTRL,0);
 /* Dedicated program is the only DMA owner; release any stale published slots. */
 c9_write(0,4,0);for(unsigned i=0;i<1000000&&(c9_read(0,0x24)&7);i++){}
 c9_write(0,0x10,c9_read(0,0x14));
 if(pdm_ring_open(&ring,&bus,(uint32_t)(uintptr_t)c9_ddr.slots,12,4000000,0,0,session,100000)){
 rec.failed=1;finish_pending=20;return;}
 run=1;last_progress=timer();sequence_base=0;capture_clock=0;Xil_Out32(CTRL,1);
}
int main(void){
 ip_addr_t ip,mask,gw;unsigned char mac[6]={0,10,53,0,2,3};
 /* Global timer enables the watchdog; it is not wall-clock UTC. */
 Xil_Out32(0xf8f00208u,1);Xil_Out32(CTRL,0);
 if(Xil_In32(CTRL+8)!=0x52393132u)return -10;
 IP4_ADDR(&ip,192,168,2,10);IP4_ADDR(&mask,255,255,255,0);IP4_ADDR(&gw,192,168,2,1);
 lwip_init();if(!xemac_add(&server_netif,&ip,&mask,&gw,mac,XPAR_XEMACPS_0_BASEADDR))return -1;
 netif_set_default(&server_netif);netif_set_up(&server_netif);if(gic_setup()!=XST_SUCCESS)return -2;
 udp=udp_new();if(!udp||udp_bind(udp,IP_ADDR_ANY,1235)!=ERR_OK)return -3;udp_recv(udp,receive,0);Xil_ExceptionEnable();
 uint32_t sent_tick=timer(),arp_tick=timer();
 while(1){
 xemacif_input(&server_netif);
 if((uint32_t)(timer()-arp_tick)>XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ*2u){etharp_tmr();arp_tick=timer();}
 if(run){
 for(unsigned n=0;n<64;n++){uint8_t slot[128];int rc=pdm_ring_next(&ring,slot);if(!rc)break;
 if(rc<0||raw9_feed(&rec,slot)<0){rec.failed=1;break;}
 last_progress=timer();
 if(rec.frames==RAW9_FRAMES){raw9_flush(&rec);break;}
 }
 if((uint32_t)(timer()-last_progress)>XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ){rec.failed=1;}
 if(rec.failed||rec.complete){if(c9_read(0,0x18)||c9_read(0,0x1c)||c9_read(0,0x20))rec.failed=1;Xil_Out32(CTRL,0);run=0;finish_pending=20;}
 }
 /* Leave the main loop frequently so input service can reap TX descriptors.
 * Failed local submissions retain the same packet, without advancing sequence. */
 for(unsigned k=0;k<4;k++){if(!raw9_tx_pump(&tx,tx_send,0))break;tx_tick=timer();}
 if(tx.head!=tx.tail&&(uint32_t)(timer()-tx_tick)>XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ){
  rec.failed=1;Xil_Out32(CTRL,0);run=0;finish_pending=20;tx.tail=tx.head;tx.offset=0;
 }
 if(finish_pending&&tx.head==tx.tail&&(uint32_t)(timer()-sent_tick)>XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ/20){
 send_packet(2,rec.frames,0,0);finish_pending--;sent_tick=timer();}
 }
}
