/* Deterministic CPU0/CPU1 interleaving: real tasks/history/FFT/diagnosis/API.
 * CPU0 ingestion continues during declared CPU1 cost, no actual ARM timing. */
#define C9_PIPELINE_NO_MAIN
#define C9_ASYNC_TEST
#include "circular9_pipeline_test.c"
#include <assert.h>
static uint64_t sim_us;
static unsigned active,reads,in_callback,aux_cost,diag_cost,injected_aux,injected_diag;
static int16_t (*input_pcm)[9];static unsigned input_count,written;
static struct ipc_page ipc;
static void cpu0_step(void){
 unsigned target=(unsigned)(sim_us*156250u/1000000u);
 for(;written<target;written++){
  uint32_t words[16];packet(words,written,7);memset(words+8,0,5*sizeof(uint32_t));
  for(unsigned ch=0;ch<9;ch++)words[8+ch/2]|=(uint32_t)(uint16_t)input_pcm[written%input_count][ch]<<(16*(ch&1));
  c9_history_push(&c9_history_shared.history,words);
 }
 c9_tasks_receive();c9_tasks_schedule();
}
static uint32_t c9_async_now(void){
 if(active&&!in_callback&&++reads==2u){
  in_callback=1;unsigned duration;
  if(c9_tasks_shared.data.job.state==2u){duration=diag_cost;injected_diag++;}
  else {duration=aux_cost;injected_aux++;}
  uint64_t end=sim_us+duration;
  while(sim_us<end){sim_us+=end-sim_us<1000u?end-sim_us:1000u;cpu0_step();}
  in_callback=0;
 }
 return (uint32_t)(sim_us*333333333u/1000000u);
}
int main(int argc,char **argv){
 if(argc!=6)return 2;aux_cost=(unsigned)strtoul(argv[3],0,10);diag_cost=(unsigned)strtoul(argv[4],0,10);unsigned duration=(unsigned)strtoul(argv[5],0,10);
 FILE *f=fopen(argv[1],"rb");assert(f);fseek(f,0,SEEK_END);long bytes=ftell(f);rewind(f);assert(bytes>0&&bytes%18==0);input_count=(unsigned)(bytes/18);input_pcm=malloc((size_t)bytes);assert(input_pcm&&fread(input_pcm,1,(size_t)bytes,f)==(size_t)bytes);fclose(f);
 c9_tasks_init();c9_tracks=(c9_tracker){0};c9_aux_tracks=(c9_tracker){.next_id=0x40000000u};c9_schedule=(c9_diagnostic_schedule){0};
 c9_shaft_confirmed=0;c9_shaft_generation=1;c9_latest_slot=-1;
 while(sim_us<(uint64_t)duration*1000000u){
  sim_us+=1000;cpu0_step();
  if(c9_tasks_shared.data.job.state==1u||c9_tasks_shared.data.auxiliary.job.state==1u){active=1;reads=0;c9_tasks_cpu1(&ipc);active=0;c9_tasks_receive();}
 }
 active=0;int length=c9_candidates_json(body,sizeof(body));assert(length>0);
 f=fopen(argv[2],"wb");assert(f);
 fprintf(f,"{\"evidence\":\"DETERMINISTIC_REAL_C_TASK_INTERLEAVING\",\"hardware_tested\":false,\"hypothetical_aux_cost_us\":%u,\"hypothetical_diag_cost_us\":%u,\"simulated_duration_us\":%llu,\"PCM_repeat_period_frames\":%u,\"injected_aux\":%u,\"injected_diag\":%u,\"api\":",aux_cost,diag_cost,(unsigned long long)sim_us,input_count,injected_aux,injected_diag);fwrite(body,1,length,f);fputs("}\n",f);fclose(f);
 assert(!ipc.busy);if(aux_cost>200000)assert(c9_tasks_shared.data.auxiliary.late>0&&c9_tasks_shared.data.metrics.started==0);
 printf("ASYNC_REAL_TASK_PASS aux_cost=%u diag_cost=%u aux_done=%u aux_late=%u diag_started=%u diag_done=%u sequence=%u\n",aux_cost,diag_cost,c9_tasks_shared.data.auxiliary.completed,c9_tasks_shared.data.auxiliary.late,c9_tasks_shared.data.metrics.started,c9_tasks_shared.data.metrics.completed,c9_latest_sequence);
 free(input_pcm);return 0;
}
