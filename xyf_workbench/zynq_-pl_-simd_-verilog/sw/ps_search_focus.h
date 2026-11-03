
static int sf_az,sf_el;
static void sf_poll(void){
 if(sf_state==1u&&__atomic_load_n(&c9_tasks_shared.data.focus_ack,__ATOMIC_ACQUIRE)){
  if(c9_listen_lock(&c9_listen,sf_az,sf_el,C9_LISTEN_OPERATOR)){c9_recording=1;sf_state=4;sf_audio_allowed=0;sf_elapsed=c9_ticks_to_us(dia_gtimer_now()-sf_started);}
 }
 if(sf_state==4u&&!c9_listen.pending&&c9_listen.actual_mode==MANUAL_GSC){sf_state=2;sf_audio_allowed=1;c9_requested=1;sf_elapsed=c9_ticks_to_us(dia_gtimer_now()-sf_started);}
 uint32_t end=0,count=0,ep=0,se=0;int fresh=c9_history_info(&c9_history_shared.history,&end,&count,&ep,&se)&&(uint32_t)(end-sf_resume_sample)>=C9_SNAPSHOT_FRAMES;
 if(sf_state==3u&&fresh&&(int32_t)(c9_aux_received_end-sf_resume_sample)>0&&!__atomic_load_n(&c9_tasks_shared.data.focus_ack,__ATOMIC_ACQUIRE)&&c9_aux_accepted!=sf_recovery_accepted){sf_state=0;sf_elapsed=c9_ticks_to_us(dia_gtimer_now()-sf_started);}
}
static int sf_route(const char *req,struct ui_reply *rep,char *body,size_t cap){
 if(sf_state!=0u&&!strncmp(req,"GET /api/listen/",16)){*rep=(struct ui_reply){409,"Conflict","application/json",0};return 1;}
 if(strncmp(req,"GET /api/system/",16))return 0;
 int a,e;char tail;
 if(sscanf(req,"GET /api/system/focus?az=%d&el=%d%c",&a,&e,&tail)==3&&tail==' '&&c9_listen_angle(a,e)&&sf_state==0){sf_az=a;sf_el=e;sf_started=dia_gtimer_now();sf_state=1;sf_audio_allowed=0;__atomic_store_n(&c9_tasks_shared.data.focus_request,1u,__ATOMIC_RELEASE);}
 else if(!strncmp(req,"GET /api/system/search ",23)&&(sf_state==1u||sf_state==2u||sf_state==4u)){sf_audio_allowed=0;c9_requested=0;c9_listen_back(&c9_listen);c9_aux_have=0;c9_schedule.have=0;sf_recovery_accepted=c9_aux_accepted;uint32_t count,ep,se;c9_history_info(&c9_history_shared.history,&sf_resume_sample,&count,&ep,&se);sf_started=dia_gtimer_now();sf_state=3;__atomic_store_n(&c9_tasks_shared.data.focus_request,0u,__ATOMIC_RELEASE);}
 else if(strncmp(req,"GET /api/system/state ",22)){*rep=(struct ui_reply){409,"Conflict","application/json",0};return 1;}
 const char *names[]={"SEARCH","ENTERING_FOCUS","FOCUS","RECOVERING_SEARCH","CONFIGURING_FOCUS"};int n=snprintf(body,cap,"{\"state\":\"%s\",\"search_diagnosis_paused\":%u,\"cpu1_quiescent\":%u,\"transition_us\":%u,\"gsc_allowed\":%u}",names[sf_state],(unsigned)(sf_state!=0),(unsigned)__atomic_load_n(&c9_tasks_shared.data.focus_ack,__ATOMIC_ACQUIRE),(unsigned)sf_elapsed,sf_audio_allowed);*rep=(struct ui_reply){200,"OK","application/json",n};return 1;
}
