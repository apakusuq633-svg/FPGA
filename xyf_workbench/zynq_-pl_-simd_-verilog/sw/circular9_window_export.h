#ifndef CIRCULAR9_WINDOW_EXPORT_H
#define CIRCULAR9_WINDOW_EXPORT_H
/* Explicit operator opt-in, OFF at boot; CPU0-owned frozen copy only.
 * Not an authenticated service: enable only on the trusted board LAN. */
#ifndef C9_WINDOW_EXPORT
#define C9_WINDOW_EXPORT 1
#endif
#if C9_WINDOW_EXPORT
#define C9_EXPORT_MAX_FRAMES 160256u
static struct {uint32_t enabled,token,valid,frames,first,epoch,session;int16_t pcm[C9_EXPORT_MAX_FRAMES][9];} c9_export;
static int c9_export_uint(const char **text,uint32_t max,uint32_t *value){
 const char *p=*text;uint32_t n=0;if(*p<'0'||*p>'9')return 0;
 do{unsigned d=(unsigned)(*p-'0');if(d>max||n>(max-d)/10u)return 0;n=n*10u+d;p++;}while(*p>='0'&&*p<='9');
 *value=n;*text=p;return 1;
}
#endif
static int c9_window_route(const char *req,struct ui_reply *rep,char *body,size_t cap){
 const char *capture="GET /api/debug/window?";
 int enable=!strncmp(req,"POST /api/debug/window/enable ",sizeof("POST /api/debug/window/enable ")-1);
 int disable=!strncmp(req,"POST /api/debug/window/disable ",sizeof("POST /api/debug/window/disable ")-1);
 if(!enable&&!disable&&strncmp(req,capture,strlen(capture)))return 0;
#if !C9_WINDOW_EXPORT
 (void)body;(void)cap;*rep=(struct ui_reply){503,"Service Unavailable","application/json",0};return 1;
#else
 if(enable||disable){
  if(cap<32u){*rep=(struct ui_reply){500,"Internal Server Error","application/json",0};return 1;}
  c9_export.enabled=enable;c9_export.valid=0;
  int len=snprintf(body,cap,"{\"enabled\":%u}",(unsigned)c9_export.enabled);
  *rep=(struct ui_reply){200,"OK","application/json",len};return 1;
 }
 if(!c9_export.enabled){*rep=(struct ui_reply){403,"Forbidden","application/json",0};return 1;}
 const char *p=req+strlen(capture);uint32_t frames=0,token=0,offset=0,count=0;
 if(!strncmp(p,"frames=",7)){
  p+=7;if(!c9_export_uint(&p,C9_EXPORT_MAX_FRAMES,&frames)||*p!=' '||frames<1024u)goto bad;
  if(cap<384u){*rep=(struct ui_reply){500,"Internal Server Error","application/json",0};return 1;}
  uint32_t end=0,available=0,epoch=0,session=0,first=0;c9_export.valid=0;
  if(!c9_history_info(&c9_history_shared.history,&end,&available,&epoch,&session)||available<frames)goto conflict;
  uint32_t start=(end&~3u)-frames;
  for(uint32_t n=0;n<frames;n+=64u){
   uint32_t size=frames-n;if(size>64u)size=64u;uint32_t ep=0,se=0;
   if(!c9_history_copy(&c9_history_shared.history,c9_export.pcm+n,size,start+n+size,&first,&ep,&se)||first!=start+n||ep!=epoch||se!=session)goto conflict;
   c9_realtime_checkpoint();
  }
  uint32_t ep=0,se=0;
  if(!c9_history_info(&c9_history_shared.history,0,0,&ep,&se)||ep!=epoch||se!=session)goto conflict;
  if(!++c9_export.token)++c9_export.token;
  c9_export.frames=frames;c9_export.first=start;c9_export.epoch=epoch;c9_export.session=session;c9_export.valid=1;
  int len=snprintf(body,cap,"{\"format\":\"C9W2\",\"version\":1,\"token\":%u,\"frames\":%u,\"channels\":9,\"sample_rate_num\":156250,\"sample_rate_den\":1,\"first_sample\":%u,\"epoch\":%u,\"session\":%u,\"max_chunk_frames\":1024,\"source\":\"live_history_frozen_copy\"}",(unsigned)c9_export.token,(unsigned)frames,(unsigned)start,(unsigned)epoch,(unsigned)session);
  *rep=(struct ui_reply){len<0||(size_t)len>=cap?500:200,len<0||(size_t)len>=cap?"Internal Server Error":"OK","application/json",len<0||(size_t)len>=cap?0:len};return 1;
 }
 if(strncmp(p,"token=",6))goto bad;
 p+=6;
 if(!c9_export_uint(&p,UINT32_MAX,&token)||strncmp(p,"&offset=",8))goto bad;
 p+=8;
 if(!c9_export_uint(&p,C9_EXPORT_MAX_FRAMES,&offset)||strncmp(p,"&count=",7))goto bad;
 p+=7;
 if(!c9_export_uint(&p,1024u,&count)||*p!=' '||!count)goto bad;
 if(!c9_export.valid||token!=c9_export.token)goto conflict;
 if(offset>=c9_export.frames||count>c9_export.frames-offset)goto bad;
 size_t bytes=48u+18u*count;if(cap<bytes){*rep=(struct ui_reply){500,"Internal Server Error","application/json",0};return 1;}
 uint32_t h[12]={0x43395732u,1u,token,156250u,1u,c9_export.frames,offset,count,c9_export.first,c9_export.epoch,c9_export.session,9u};memcpy(body,h,sizeof(h));
 for(uint32_t i=0;i<count;i++){
  for(unsigned ch=0;ch<9;ch++){uint16_t v=(uint16_t)c9_export.pcm[offset+i][ch];body[48+18*i+2*ch]=(char)v;body[49+18*i+2*ch]=(char)(v>>8);}
  if((i&63u)==63u)c9_realtime_checkpoint();
 }
 *rep=(struct ui_reply){200,"OK","application/octet-stream",(int)bytes};return 1;
 bad:*rep=(struct ui_reply){400,"Bad Request","application/json",0};return 1;
 conflict:*rep=(struct ui_reply){409,"Conflict","application/json",0};return 1;
#endif
}
#endif
