/* Executes the actual application loop against modeled DDR/MMIO and lwIP. */
#define _GNU_SOURCE
#include <sys/mman.h>
#include <assert.h>
#include <stdarg.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ps_stream_mock.h"
#define main pdm_app_main
#include "../sw/ps_stream_udp.c"
#undef main
static uint32_t mock_regs[32],mock_ticks,mock_timer,mock_frame,mock_iterations;
static uint32_t mock_invalidates,mock_flushes,mock_allocs,mock_fault_injected,mock_success_frames;
static unsigned mock_fault_mode;
static uint32_t mock_total=256;
static uint8_t mock_packets[256][64];
static FILE *mock_capture;
static jmp_buf mock_done;
static void mock_put(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
uint32_t Xil_In32(uint32_t a){
 if(a>=DMA_BASE&&a<DMA_BASE+sizeof mock_regs)return mock_regs[(a-DMA_BASE)/4];
 if(a==GT_BASE){if(mock_timer)mock_ticks+=25;return mock_ticks;}
 if(a==GT_BASE+4)return 0;
 if(a==GT_BASE+8)return mock_timer;
 assert(0);return 0;
}
void Xil_Out32(uint32_t a,uint32_t v){
 if(a==GT_BASE+8){mock_timer=v;return;}
 assert(a>=DMA_BASE&&a<DMA_BASE+sizeof mock_regs);
 unsigned i=(a-DMA_BASE)/4;
 if(i==1){
  if(v&6u)mock_regs[9]&=~16u;
  mock_regs[1]=v&1u;mock_regs[9]=(mock_regs[9]&~8u)|((v&1u)<<3);
 }else if(i==16){mock_regs[4]=mock_regs[5]=v;}
 else mock_regs[i]=v;
}
void Xil_DCacheInvalidateRange(uint32_t a,size_t n){assert(a>=0x08000000&&a+n<=0x08080000&&n==128&&!(a&127));mock_invalidates++;}
void Xil_DCacheFlushRange(uint32_t a,size_t n){assert(a==0x08000000&&n==0x80000);mock_flushes++;}
int xil_printf(const char *f,...){va_list ap;va_start(ap,f);int n=vprintf(f,ap);va_end(ap);return n;}
static XScuGic_Config mock_cfg={0};
XScuGic_Config *XScuGic_LookupConfig(unsigned id){assert(id==0);return &mock_cfg;}
int XScuGic_CfgInitialize(XScuGic *g,XScuGic_Config *c,uint32_t a){(void)g;(void)c;(void)a;return 0;}
int XScuGic_Connect(XScuGic *g,unsigned i,Xil_ExceptionHandler h,void *c){(void)g;(void)i;(void)h;(void)c;return 0;}
void XScuGic_InterruptHandler(void *c){(void)c;}
void XEmacPs_IntrHandler(void *c){(void)c;}
void XScuGic_Enable(XScuGic *g,unsigned i){(void)g;(void)i;}
void Xil_ExceptionInit(void){}
void Xil_ExceptionRegisterHandler(unsigned i,Xil_ExceptionHandler h,void *c){(void)i;(void)h;(void)c;}
void Xil_ExceptionEnable(void){}
void lwip_init(void){}
int ipaddr_aton(const char *s,ip_addr_t *a){(void)s;a->value=0;return 1;}
struct netif *xemac_add(struct netif *n,ip_addr_t *i,ip_addr_t *m,ip_addr_t *g,unsigned char *mac,uint32_t a){
 (void)i;(void)m;(void)g;(void)mac;assert(a==XPAR_XEMACPS_0_BASEADDR);
 static xemacpsif_s e;static struct xemac_s x;x.state=&e;n->state=&x;return n;
}
void netif_set_default(struct netif *n){(void)n;}
void netif_set_up(struct netif *n){(void)n;}
struct udp_pcb *udp_new(void){static struct udp_pcb p;return &p;}
err_t udp_bind(struct udp_pcb *p,const ip_addr_t *a,unsigned port){(void)p;(void)a;assert(port==1234);return 0;}
void etharp_tmr(void){}
void eth_link_detect(struct netif *n){(void)n;}
void xemacif_input(struct netif *n){
 (void)n;mock_iterations++;
 if(mock_frame<mock_total&&(mock_regs[1]&1u)){
  uint32_t owner=mock_regs[5],sample=mock_frame;
  assert(owner-mock_regs[4]<(1u<<mock_regs[3]));
  uint8_t *p=(uint8_t *)(uintptr_t)(mock_regs[2]+((owner&((1u<<mock_regs[3])-1))<<7));
  memset(p,0,128);memcpy(p,mock_packets[mock_frame&255u],64);
  if(mock_fault_mode&&mock_frame>=38)sample=mock_frame-38;
  mock_put(p+4,sample);mock_put(p+64,17+sample*1024);
  mock_put(p+72,owner);mock_put(p+80,0x394d4450);mock_put(p+84,128);
  mock_put(p+88,mock_regs[17]);mock_put(p+92,0x0010000c);
  mock_put(p+120,pdm_crc32(p,120));mock_put(p+124,~owner);
  if(mock_fault_mode&&mock_frame==9)p[100]^=1;
  mock_regs[5]++;mock_frame++;
 }
 if(mock_fault_mode&&mock_frame==mock_total&&!mock_fault_injected){mock_regs[9]|=16u;mock_fault_injected=1;}
 if(mock_frame==mock_total&&mock_iterations>mock_total+50000u)longjmp(mock_done,1);
}
struct pbuf *pbuf_alloc(unsigned a,u16_t n,unsigned t){
 (void)a;(void)t;mock_allocs++;
 if(mock_fault_mode&&mock_allocs==5)return NULL;
 struct pbuf *p=malloc(sizeof(*p));assert(p);p->payload=malloc(n);assert(p->payload);p->length=n;return p;
}
err_t pbuf_take(struct pbuf *p,const void *s,u16_t n){assert(n==p->length);memcpy(p->payload,s,n);return ERR_OK;}
err_t udp_sendto(struct udp_pcb *p,struct pbuf *b,const ip_addr_t *a,unsigned port){
 (void)p;(void)a;assert(port==1234);
 if(mock_fault_mode&&mock_allocs==3)return ERR_MEM;
 uint32_t length=b->length;assert(fwrite(&length,4,1,mock_capture)==1);
 assert(fwrite(b->payload,length,1,mock_capture)==1);
 mock_success_frames+=(uint32_t)((uint8_t *)b->payload)[20];return ERR_OK;
}
void pbuf_free(struct pbuf *p){free(p->payload);free(p);}
int main(int argc,char **argv){
 assert(argc==4||argc==5);mock_fault_mode=(unsigned)atoi(argv[3]);
 if(argc==5)mock_total=(uint32_t)strtoul(argv[4],NULL,10);
 assert(mock_total>=256&&mock_total<=1000000);
 FILE *f=fopen(argv[1],"rb");assert(f&&fread(mock_packets,sizeof mock_packets,1,f)==1);fclose(f);
 mock_capture=fopen(argv[2],"wb");assert(mock_capture);
 assert(mmap((void *)0x08000000,0x80000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0)==(void *)0x08000000);
 mock_regs[0]=0x394d4450;
 if(!setjmp(mock_done)){int status=pdm_app_main();fprintf(stderr,"unexpected app exit %d\n",status);return 1;}
 fclose(mock_capture);
 assert(mock_invalidates==mock_total&&mock_flushes==1&&mock_regs[4]==mock_regs[5]);
 assert(pdm_ring_stat(&ring,PDM_FRAME_OK)==mock_total-(mock_fault_mode?1u:0u));
 assert(pdm_ring_stat(&ring,PDM_CORRUPT)==(mock_fault_mode?1u:0u));
 assert(mock_success_frames+discarded_frames+pdm_ring_stat(&ring,PDM_CORRUPT)==mock_total);
 assert(pdm_ring_stat(&ring,PDM_SOURCE_RESTARTS)==(mock_fault_mode?1u:0u));
 assert(pdm_ring_stat(&ring,PDM_RECOVERIES)==(mock_fault_mode?1u:0u));
 assert(encode_errors==0);
 printf("PS_STREAM_APP_MOCK_PASS generated=%u sent_frames=%u discarded=%u corrupt=%u active=%u recoveries=%u\n",
 mock_total,mock_success_frames,discarded_frames,(unsigned)pdm_ring_stat(&ring,PDM_CORRUPT),
 (unsigned)gsc12_stat(&gsc,GSC12_ACTIVE),(unsigned)pdm_ring_stat(&ring,PDM_RECOVERIES));
 return 0;
}
