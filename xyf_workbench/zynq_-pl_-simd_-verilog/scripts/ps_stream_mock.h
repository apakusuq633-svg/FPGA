/* Host-only substitutes for PS peripheral/lwIP APIs. No hardware code. */
#ifndef PS_STREAM_MOCK_H
#define PS_STREAM_MOCK_H
#include <stdint.h>
#include <stddef.h>
#define XPAR_SCUGIC_0_DEVICE_ID 0
#define XPAR_XEMACPS_0_INTR 54
#define XPAR_XEMACPS_0_BASEADDR 0xe000b000u
#define XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ 2000000u
#define XST_SUCCESS 0
#define XIL_EXCEPTION_ID_INT 5
#define ERR_OK 0
#define ERR_MEM -1
#define PBUF_TRANSPORT 0
#define PBUF_RAM 0
typedef int err_t;
typedef uint16_t u16_t;
typedef struct {uint32_t value;} ip_addr_t;
#define IP_ADDR_ANY ((const ip_addr_t *)0)
typedef void (*Xil_ExceptionHandler)(void *);
typedef struct {unsigned dummy;} XScuGic;
typedef struct {uint32_t CpuBaseAddress;} XScuGic_Config;
typedef struct {unsigned dummy;} XEmacPs;
typedef struct {XEmacPs emacps;} xemacpsif_s;
struct xemac_s {void *state;};
struct netif {void *state;};
struct udp_pcb {unsigned dummy;};
struct pbuf {void *payload;unsigned length;};
uint32_t Xil_In32(uint32_t);
void Xil_Out32(uint32_t,uint32_t);
void Xil_DCacheInvalidateRange(uint32_t,size_t);
void Xil_DCacheFlushRange(uint32_t,size_t);
int xil_printf(const char *,...);
XScuGic_Config *XScuGic_LookupConfig(unsigned);
int XScuGic_CfgInitialize(XScuGic *,XScuGic_Config *,uint32_t);
int XScuGic_Connect(XScuGic *,unsigned,Xil_ExceptionHandler,void *);
void XScuGic_InterruptHandler(void *);
void XEmacPs_IntrHandler(void *);
void XScuGic_Enable(XScuGic *,unsigned);
void Xil_ExceptionInit(void);
void Xil_ExceptionRegisterHandler(unsigned,Xil_ExceptionHandler,void *);
void Xil_ExceptionEnable(void);
void lwip_init(void);
int ipaddr_aton(const char *,ip_addr_t *);
struct netif *xemac_add(struct netif *,ip_addr_t *,ip_addr_t *,ip_addr_t *,unsigned char *,uint32_t);
void netif_set_default(struct netif *);
void netif_set_up(struct netif *);
struct udp_pcb *udp_new(void);
err_t udp_bind(struct udp_pcb *,const ip_addr_t *,unsigned);
void xemacif_input(struct netif *);
void etharp_tmr(void);
void eth_link_detect(struct netif *);
struct pbuf *pbuf_alloc(unsigned,u16_t,unsigned);
err_t pbuf_take(struct pbuf *,const void *,u16_t);
err_t udp_sendto(struct udp_pcb *,struct pbuf *,const ip_addr_t *,unsigned);
void pbuf_free(struct pbuf *);
#endif
