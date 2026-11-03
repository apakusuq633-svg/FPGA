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
typedef struct {unsigned sequence,count,session,epoch,shaft_generation,deadline_missed; c9_diag_report diagnosis[3];unsigned gui_envelope_valid[3];uint16_t gui_envelope[3][128];int16_t audio[3][C9_DIAG_SAMPLES];} c9_diagnostic_result;
static int c9_latest_slot=-1;
static struct {struct {c9_diagnostic_result results[2];} data;} c9_tasks_shared;
static unsigned c9_shaft_confirmed=1,c9_shaft_millihz=25000;
static int c9_result_current(const c9_diag_report *d,unsigned session,unsigned generation){(void)d;(void)session;(void)generation;return 1;}
static struct {int history;} c9_history_shared;
static unsigned hist_end=2048,hist_count=2048,hist_epoch=3,hist_session=4,hist_fail_call,hist_copy_calls,hist_change_call;
static int c9_history_info(const int *h,uint32_t *end,uint32_t *count,uint32_t *epoch,uint32_t *session){(void)h;if(end)*end=hist_end;if(count)*count=hist_count;if(epoch)*epoch=hist_epoch;if(session)*session=hist_session;return 1;}
static int c9_history_copy(const int *h,int16_t (*r)[9],uint32_t count,uint32_t end,uint32_t *first,uint32_t *epoch,uint32_t *session){
 (void)h;hist_copy_calls++;if(hist_copy_calls==hist_fail_call)return 0;if(hist_copy_calls==hist_change_call)hist_epoch++;*first=end-count;*epoch=hist_epoch;*session=hist_session;for(unsigned i=0;i<count;i++)for(unsigned j=0;j<9;j++)r[i][j]=(int16_t)(*first+i+j);return 1;
}
static unsigned checkpoints;
static void c9_realtime_checkpoint(void){checkpoints++;}
#define C9_HISTORY_FRAMES 1048576u
#define ACOUSTIC_GEOMETRY_VERSION 1u
#define C9_EVIDENCE_BUILD_ID "mock"
static int c9_source_exists(unsigned o,uint32_t q,uint32_t se,uint32_t ep,uint32_t f,uint32_t e){(void)o;(void)q;(void)se;(void)ep;(void)f;(void)e;return 0;}
#include "sw/ps_circular9_gui.h"
static char out[61440];
static struct ui_reply request(const char *s,int expected){struct ui_reply r;memset(out,0,sizeof(out));assert(c9_gui_route(s,&r,out,sizeof(out)));assert(r.code==expected);return r;}
int main(int argc,char **argv){
 c9h_init(&c9_health);c9_gui_poll();
 request("GET /api/health9/status HTTP/1.1",200);puts(out);
 request("GET /api/health9/config?suspect=4&alarm=6&recover=12 HTTP/1.1",200);
 assert(c9_health.suspect==4&&c9_health.alarm==6&&c9_health.recover==12);
 request("GET /api/health9/config?suspect=8&alarm=2&recover=12 HTTP/1.1",400);
 assert(c9_health.suspect==4);
 request("GET /api/health9/config?suspect=0&alarm=6&recover=12 HTTP/1.1",400);

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

 c9_diagnostic_result *snap=&c9_tasks_shared.data.results[0];snap->gui_envelope_valid[0]=1;
 snap->diagnosis[0].extraction.status=C9_DIAG_EXTRACT_OK;snap->diagnosis[0].extraction.fft_count=1;
 snap->diagnosis[0].binding.first_sample=123456;snap->diagnosis[0].binding.epoch=3;snap->session=4;
 snap->audio[0][0]=-1234;snap->audio[0][4095]=2345;snap->gui_envelope[0][127]=987;
 r=request("GET /api/gui/snapshot?sequence=1&index=0 HTTP/1.1",200);assert(r.len==8512);
 uint32_t h[16];memcpy(h,out,sizeof(h));assert(h[0]==0x43394732&&h[1]==1&&h[2]==1&&h[3]==7&&h[7]==4096&&h[8]==128);
 assert(h[9]==1&&h[10]==C9_DIAG_EXTRACT_OK&&h[11]==123456&&h[12]==3&&h[13]==4&&h[14]==0&&h[15]==0);
 if(argc>1){FILE *f=fopen(argv[1],"wb");assert(f);assert(fwrite(out,1,(size_t)r.len,f)==(size_t)r.len);fclose(f);}

 uint16_t sample;memcpy(&sample,out+64,2);assert((int16_t)sample==-1234);memcpy(&sample,out+64+8190,2);assert(sample==2345);
 memcpy(&sample,out+8256+254,2);assert(sample==987);
 snap->diagnosis[0].shaft_hz=30;request("GET /api/gui/snapshot?sequence=1&index=0 HTTP/1.1",200);memcpy(h,out,sizeof(h));assert(h[14]==30000&&h[15]==1);
 request("GET /api/gui/snapshot?sequence=2&index=0 HTTP/1.1",409);
 request("GET /api/gui/snapshot?sequence=1&index=3 HTTP/1.1",400);
 request("GET /api/gui/snapshot?sequence=1&index=1 HTTP/1.1",409);
 request("GET /api/gui/snapshot?sequence=1&index=0XYZ HTTP/1.1",400);
 assert(c9_gui_route("GET /api/gui/snapshot?sequence=1&index=0 HTTP/1.1",&r,out,64)&&r.code==500&&r.len==0);

#if C9_WINDOW_EXPORT
 assert(!c9_export.enabled&&!c9_export.valid);
 request("GET /api/debug/window?frames=16640 HTTP/1.1",403);
 struct ui_reply ignored;assert(!c9_window_route("GET /api/debug/window/enable HTTP/1.1",&ignored,out,sizeof(out))&&!c9_export.enabled);
 request("POST /api/debug/window/enable HTTP/1.1",200);assert(c9_export.enabled&&!c9_export.valid);
 request("GET /api/debug/window?frames=16640 HTTP/1.1",409);
 hist_end=hist_count=200000;hist_copy_calls=0;
 request("GET /api/debug/window?frames=160256 HTTP/1.1",200);assert(c9_export.valid&&c9_export.first==39744u&&c9_export.frames==160256u);
 unsigned token=c9_export.token;char query[160];
 for(unsigned offset=0;offset<160256;offset+=1024){
  unsigned n=160256-offset;if(n>1024)n=1024;
  snprintf(query,sizeof(query),"GET /api/debug/window?token=%u&offset=%u&count=%u HTTP/1.1",token,offset,n);r=request(query,200);assert(r.len==(int)(48+18*n));
  uint32_t header[12];memcpy(header,out,48);assert(header[0]==0x43395732&&header[2]==token&&header[5]==160256&&header[6]==offset&&header[7]==n&&header[8]==39744&&header[9]==3&&header[10]==4&&header[11]==9);
  for(unsigned i=0;i<n;i++)for(unsigned ch=0;ch<9;ch++){int16_t x;memcpy(&x,out+48+18*i+2*ch,2);assert(x==(int16_t)(39744+offset+i+ch));}
 }
 /* Frozen cache survives producer advancement; it never joins new windows. */
 hist_end+=100000;hist_epoch++;snprintf(query,sizeof(query),"GET /api/debug/window?token=%u&offset=0&count=1 HTTP/1.1",token);request(query,200);
 request("GET /api/debug/window?frames=16640 HTTP/1.1",200);assert(c9_export.token!=token);request(query,409);
 const char *bad[]={"frames=-1","frames=4294967297","frames=0","frames=160257","frames=16640&x=1","token=1&offset=0&count=0","token=1&offset=0&count=1025","token=4294967297&offset=0&count=1","token=1&offset=-1&count=1"};
 for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++){snprintf(query,sizeof(query),"GET /api/debug/window?%s HTTP/1.1",bad[i]);request(query,400);}
 snprintf(query,sizeof(query),"GET /api/debug/window?token=%u&offset=16640&count=1 HTTP/1.1",c9_export.token);request(query,400);
 hist_copy_calls=0;hist_fail_call=2;request("GET /api/debug/window?frames=16640 HTTP/1.1",409);assert(!c9_export.valid);hist_fail_call=0;
 hist_copy_calls=0;hist_change_call=2;request("GET /api/debug/window?frames=16640 HTTP/1.1",409);assert(!c9_export.valid);hist_change_call=0;
 request("GET /api/debug/window?frames=16640 HTTP/1.1",200);
 snprintf(query,sizeof(query),"GET /api/debug/window?token=%u&offset=0&count=1024 HTTP/1.1",c9_export.token);
 assert(c9_gui_route(query,&r,out,48)&&r.code==500&&r.len==0);
 request("POST /api/debug/window/disable HTTP/1.1",200);assert(!c9_export.enabled&&!c9_export.valid);request(query,403);
 request("POST /api/debug/window/enable HTTP/1.1",200);request(query,409);request("POST /api/debug/window/disable HTTP/1.1",200);
 puts("C9_WINDOW_EXPORT_PASS default_off=1 explicit_POST=1 full_window=160256 chunks=157 era_change_rejected=1 failure_invalidates=1 disable_revokes=1");
#else
 request("POST /api/debug/window/enable HTTP/1.1",503);
 request("GET /api/debug/window?frames=16640 HTTP/1.1",503);
 puts("C9_WINDOW_EXPORT_COMPILED_OUT_PASS");
#endif
 puts("C9_GUI_API_PASS");return 0;
}
