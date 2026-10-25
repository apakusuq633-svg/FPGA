#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "sw/circular9_diagnosis.h"
#include "sw/circular9_http_args.h"
#define XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ 666666666u
struct ui_reply{int code;const char *reason,*ctype;int len;};
static unsigned ticks;
static unsigned c9_recording,c9_batch,c9_udp_tail,c9_udp_head;
static uint32_t dia_gtimer_now(void){return ticks+=10000;}
static int ui_append(char *s,int cap,int n,const char *fmt,...){
 if(n<0||n>=cap)return -1;va_list args;va_start(args,fmt);int k=vsnprintf(s+n,(size_t)(cap-n),fmt,args);va_end(args);return k<0||k>=cap-n?-1:n+k;
}
typedef struct {unsigned sequence,count,session,epoch,shaft_generation,deadline_missed; c9_diag_report diagnosis[3];unsigned gui_envelope_valid[3];uint16_t gui_envelope[3][128];} c9_diagnostic_result;
static int c9_latest_slot=-1;
static struct {struct {c9_diagnostic_result results[2];} data;} c9_tasks_shared;
static unsigned c9_shaft_confirmed=1,c9_shaft_millihz=25000;
static int c9_result_current(const c9_diag_report *d,unsigned session,unsigned generation){(void)d;(void)session;(void)generation;return 1;}
static struct {int history;} c9_history_shared;
static int c9_history_info(const int *h,uint32_t *end,uint32_t *count,uint32_t *epoch,uint32_t *session){(void)h;*end=2048;*count=2048;*epoch=3;*session=4;return 1;}
static int c9_history_copy(const int *h,int16_t (*r)[9],uint32_t count,uint32_t end,uint32_t *first,uint32_t *epoch,uint32_t *session){
 (void)h;*first=end-count;*epoch=3;*session=4;for(unsigned i=0;i<count;i++)for(unsigned j=0;j<9;j++)r[i][j]=(int16_t)(*first+i+j);return 1;
}
static unsigned checkpoints;
static void c9_realtime_checkpoint(void){checkpoints++;}
#include "sw/ps_circular9_gui.h"
static char out[61440];
static struct ui_reply request(const char *s,int expected){struct ui_reply r;memset(out,0,sizeof(out));assert(c9_gui_route(s,&r,out,sizeof(out)));assert(r.code==expected);return r;}
int main(void){
 c9h_init(&c9_health);c9_gui_poll();
 request("GET /api/health9/status HTTP/1.1",200);puts(out);
 request("GET /api/health9/statusXYZ HTTP/1.1",400);
 request("GET /api/health9/session/12345 HTTP/1.1",200);assert(c9_health.archive_session==12345);
 request("GET /api/health9/session/12346 HTTP/1.1",409);
 request("GET /api/health9/enabled?value=0 HTTP/1.1",200);assert(!c9_health.enabled);
 request("GET /api/health9/enabled?value=1 HTTP/1.1",200);
 request("GET /api/health9/enabled?value=2 HTTP/1.1",400);
 request("GET /api/health9/history?after=0&limit=0 HTTP/1.1",400);
 request("GET /api/health9/history?after=0&limit=32 HTTP/1.1",200);puts(out);
 request("GET /api/health9/events?after=0&limit=16 HTTP/1.1",200);puts(out);
 struct ui_reply r=request("GET /api/debug/pair?a=0&b=1 HTTP/1.1",200);assert(r.len==4128&&checkpoints==16);assert((unsigned char)out[0]==0x31);
 request("GET /api/debug/pair?a=0&b=0 HTTP/1.1",400);
 request("GET /api/debug/pair?a=9&b=1 HTTP/1.1",400);
 r=request("GET /api/debug/raw HTTP/1.1",200);assert(r.len==18464&&(unsigned char)out[1]==0x52);
 request("GET /api/gui/plots?sequence=1&index=0 HTTP/1.1",409);
 c9_latest_slot=0;c9_tasks_shared.data.results[0].sequence=1;c9_tasks_shared.data.results[0].count=1;
 c9_tasks_shared.data.results[0].diagnosis[0].binding.track_id=7;
 request("GET /api/gui/plots?sequence=1&index=0 HTTP/1.1",200);puts(out);
 request("GET /api/gui/plots?sequence=1&index=3 HTTP/1.1",400);
 request("GET /api/gui/plots?sequence=2&index=0 HTTP/1.1",409);
 puts("C9_GUI_API_PASS");return 0;
}
