/* Host only: real guarded history + HTTP route; synthetic transport fixture. */
#include <stdio.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "circular9_candidates.h"
#include "acoustic_circular9_image.h"
typedef struct {uint32_t state,sequence,generation,processing_us;c9_search_feedback feedback;c9_search_debug debug;} c9_aux_result;
#include "circular9_source_events.h"
static struct {c9_history history;} c9_history_shared;
struct ui_reply {int code;const char *reason,*ctype;int len;};
static int ui_append(char *dst,int cap,int off,const char *fmt,...){if(off<0||off>=cap)return -1;va_list ap;va_start(ap,fmt);int n=vsnprintf(dst+off,cap-off,fmt,ap);va_end(ap);return n<0||n>=cap-off?-1:off+n;}
static unsigned checkpoint_mode;
static void c9_realtime_checkpoint(void){
 if(checkpoint_mode==1)c9_history_shared.history.epoch++;
 if(checkpoint_mode==2){c9_history_shared.history.end+=C9_HISTORY_FRAMES;c9_history_shared.history.count=C9_HISTORY_FRAMES;}
 checkpoint_mode=0;
}
#include "circular9_window_export.h"
static char body[61440];
static void history(uint32_t first,uint32_t frames){
 c9_history *h=&c9_history_shared.history;memset(h,0,sizeof(*h));h->end=first+frames;h->count=frames;h->epoch=3;h->session=7;
 for(uint32_t n=0;n<frames;n++){uint32_t seq=first+n;c9_history_frame *f=&h->frames[seq&(C9_HISTORY_FRAMES-1)];f->sequence=seq;f->guard=2;for(unsigned ch=0;ch<9;ch++)f->pcm[ch]=(int16_t)(seq+ch*17);}
}
static void source(uint32_t first){c9_aux_result *p=&c9_source_aux.events[0];memset(p,0,sizeof(*p));p->sequence=13;p->debug=(c9_search_debug){.first=first,.end=first+16640,.session=7,.epoch=3};c9_source_aux.writes=1;}
static void request(const char *q,int code){struct ui_reply r;assert(c9_window_route(q,&r,body,sizeof(body)));if(r.code!=code){fprintf(stderr,"%s expected%d got%d\n",q,code,r.code);abort();}}
static void exact(uint32_t first,int code){char q[256];snprintf(q,sizeof(q),"GET /api/debug/window?frames=16640&first=%u&end=%u&session=7&epoch=3&sequence=13&origin=PS_AUX HTTP/1.1",first,first+16640);request(q,code);}
int main(void){
 request("POST /api/debug/window/enable HTTP/1.1",200);
 history(40000,200000);source(80000);exact(80000,200);assert(c9_export.first==80000&&c9_export.frames==16640);
 for(unsigned n=0;n<16640;n++)for(unsigned ch=0;ch<9;ch++)assert(c9_export.pcm[n][ch]==(int16_t)(80000+n+17*ch));
 request("GET /api/debug/window?token=999&offset=0&count=4 HTTP/1.1",409);
 request("GET /api/debug/window?frames=160260 HTTP/1.1",400);
 request("GET /api/debug/window?frames=16640&first=80000&end=96640&session=8&epoch=3&sequence=13&origin=PS_AUX HTTP/1.1",409);
 request("GET /api/debug/window?frames=16640&first=80000&end=96640&session=7&epoch=4&sequence=13&origin=PS_AUX HTTP/1.1",409);
 request("GET /api/debug/window?frames=16640&first=80000&end=96640&session=7&epoch=3&sequence=14&origin=PS_AUX HTTP/1.1",409);
 history(100000,200000);source(80000);exact(80000,409);
 history(C9_HISTORY_FRAMES-1000,40000);source(C9_HISTORY_FRAMES-512);exact(C9_HISTORY_FRAMES-512,200);
 history(0xfffff000u,40000);source(0xfffff800u);exact(0xfffff800u,200);
 history(40000,200000);source(80000);checkpoint_mode=1;exact(80000,409);assert(!c9_export.valid);
 history(40000,200000);source(80000);checkpoint_mode=2;exact(80000,409);assert(!c9_export.valid);
 history(40000,200000);source(80000);c9_history_shared.history.frames[80000].guard|=1;exact(80000,409);
 history(40000,200000);
 c9_source_pl.events[0]=(c9_source_primary){.first=80001,.end=81025,.session=7,.epoch=3,.sequence=22};c9_source_pl.writes=1;
 request("GET /api/debug/window?frames=1028&first=80001&end=81025&session=7&epoch=3&sequence=22&origin=PL_MAIN_MAP HTTP/1.1",200);
 assert(c9_export.first==80000&&c9_export.frames==1028);
 assert(strstr(body,"\"source_first\":80001")&&strstr(body,"\"source_end\":81025"));
 request("GET /api/debug/window?frames=16640 HTTP/1.1",200);assert(c9_export.first==223360);
 printf("EXACT_EXPORT_PASS source+range+era+ring+u32wrap+overwrite+token; primary_event=%u aux_event=%u rings=%u\n",(unsigned)sizeof(c9_source_primary),(unsigned)sizeof(c9_aux_result),(unsigned)(sizeof(c9_source_pl)+sizeof(c9_source_aux)));
 return 0;
}
