#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <assert.h>
#include "circular9_candidates.h"
#define ACOUSTIC_GEOMETRY_VERSION 123u
typedef struct {uint32_t state,sequence,generation,processing_us;c9_search_feedback feedback;c9_search_debug debug;} c9_aux_result;
#include "circular9_source_events.h"
static int ui_append(char *dst,int cap,int off,const char *fmt,...){if(off<0||off>=cap)return -1;va_list ap;va_start(ap,fmt);int n=vsnprintf(dst+off,cap-off,fmt,ap);va_end(ap);return n<0||n>=cap-off?-1:off+n;}
#include "../build/evidence_event_serializers.h"

int main(void){static char out[61440];
 c9_source_aux.writes=130;
 for(unsigned i=0;i<128;i++){
  c9_aux_result *v=&c9_source_aux.events[i];v->sequence=i;v->debug.count=511;v->debug.first=80000;v->debug.end=96640;
  for(unsigned k=0;k<9;k++){c9_debug_peak *p=&v->debug.peaks[k];memset(p,0xff,sizeof(*p));p->score=-2147483647;p->az=-90000;p->el=-90000;}}
 int n=c9_source_events_request("GET /api/candidates?events=PS_AUX&after=0&limit=4 HTTP/1.1",out,sizeof(out));assert(n>0&&n<61440);assert(strstr(out,"\"lost_before_cursor\":2"));assert(strstr(out,"\"next_after\":6"));puts(out);
 assert(c9_source_events_json("PS_AUX&after=131&limit=4 HTTP/1.1",out,sizeof(out))==-2);
 assert(c9_source_events_json("PS_AUX&after=0&limit=5 HTTP/1.1",out,sizeof(out))==-2);
 assert(c9_source_events_request("GET /api/candidates?events=PL_MAIN_MAP&after=0&limit=1 HTTP/1.1",out,sizeof(out))>0);
 assert(c9_source_events_request("GET /api/candidates?eventsX=PS_AUX&after=0&limit=1 HTTP/1.1",out,sizeof(out))==-3);
 c9_source_pl.writes=2050;n=c9_source_events_json("PL_MAIN_MAP&after=0&limit=32 HTTP/1.1",out,sizeof(out));assert(n>0&&strstr(out,"\"next_after\":34"));
 assert(c9_source_events_json("PL_MAIN_MAP&after=0&limit=32 HTTP/1.1",out,16)<0);
 return 0;
}
