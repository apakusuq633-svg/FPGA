#ifndef CIRCULAR9_SOURCE_EVENTS_H
#define CIRCULAR9_SOURCE_EVENTS_H
/* CPU0-only bounded evidence storage. Does not feed search/tracking decisions. */
#if defined(C9_EVIDENCE_OBSERVER_BUILD) && defined(C9_EXPERIMENT_CONSENSUS)
#error Observation release must not enable consensus weighting
#endif
#ifndef C9_EVIDENCE_BUILD_ID
#define C9_EVIDENCE_BUILD_ID "unrecorded"
#endif
#define C9_SOURCE_AUX_CAP 128u
#define C9_SOURCE_PL_CAP 2048u
typedef struct {uint32_t sequence,session,epoch,first,end,count,reason;c9_candidate peaks[3];} c9_source_primary;
static struct {uint32_t writes;c9_source_primary events[C9_SOURCE_PL_CAP];} c9_source_pl;
static struct {uint32_t writes;c9_aux_result events[C9_SOURCE_AUX_CAP];} c9_source_aux;
static uint32_t c9_debug_json_last_us,c9_debug_json_max_us,c9_debug_json_calls;
static int c9_source_uint(const char **text,uint32_t max,uint32_t *value){
 const char *p=*text;uint32_t n=0;if(*p<'0'||*p>'9')return 0;
 do{unsigned d=(unsigned)(*p-'0');if(d>max||n>(max-d)/10u)return 0;n=n*10u+d;p++;}while(*p>='0'&&*p<='9');
 *value=n;*text=p;return 1;
}
/* origin: 0=PL_MAIN_MAP, 1=PS_AUX; end is EXCLUSIVE, uint32 sample arithmetic. */
static int c9_source_exists(unsigned origin,uint32_t seq,uint32_t session,uint32_t epoch,uint32_t first,uint32_t end){
 if(origin){unsigned n=c9_source_aux.writes<C9_SOURCE_AUX_CAP?c9_source_aux.writes:C9_SOURCE_AUX_CAP;
  for(unsigned i=0;i<n;i++){const c9_aux_result *p=&c9_source_aux.events[i];const c9_search_debug *d=&p->debug;
   if(p->sequence==seq&&d->session==session&&d->epoch==epoch&&d->first==first&&d->end==end)return 1;}
 }else{unsigned n=c9_source_pl.writes<C9_SOURCE_PL_CAP?c9_source_pl.writes:C9_SOURCE_PL_CAP;
  for(unsigned i=0;i<n;i++){const c9_source_primary *p=&c9_source_pl.events[i];
   if(p->sequence==seq&&p->session==session&&p->epoch==epoch&&p->first==first&&p->end==end)return 1;}}
 return 0;
}
#endif
