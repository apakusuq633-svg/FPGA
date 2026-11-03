/* Actual PCM block -> segments -> features -> classifier -> IPC -> UI JSON, on host. */
#include <assert.h>
#include <stdio.h>
#include <stdarg.h>
#include "ps_diag.h"
#include "ps_das_replay.h"
#include "ps_das_audio.h"
#include "ps_das_plots.h"
#include "ps_ipc.h"
#include "ps_ui_page.h"
void xil_printf(const char *fmt,...) {(void)fmt;}
static das_segment_queue q;
static double source[DAS_AUDIO_SEGMENT],copy[DAS_AUDIO_SEGMENT];
static struct ipc_page ipc;
int main(void)
{
    unsigned i;double peak=0;das_audio_block b;das_segment *segment;
    struct ipc_frame f,received;struct diag_result baseline;
    struct ui_status status;char json[UI_BODY_MAX];
    uint32_t cursor=0;FILE *file;
    dia_synth_frame(source,DAS_AUDIO_SEGMENT);
    for(i=0;i<DAS_AUDIO_SEGMENT;i++){double v=source[i];if(v<0)v=-v;if(v>peak)peak=v;}
    for(i=0;i<DAS_AUDIO_SEGMENT;i++)source[i]*=0.8/peak;
    das_queue_init(&q);
    for(i=0;i<79;i++){das_replay_block(source,DAS_AUDIO_SEGMENT,i,(uint64_t)i*512,&b);assert(das_queue_push(&q,&b)==DAS_OK);}
    segment=das_queue_take(&q);assert(segment && segment->desc.sample_count==40000);
    memset(&f,0,sizeof f);f.audio.desc=segment->desc;
    memcpy(copy,segment->samples,sizeof copy);das_queue_release(segment);
    fea_setup(FRAME_FS,1400.0,4600.0);dia_classify_audio(copy,40000,25.0,&f.r);
    dia_classify_audio(source,40000,25.0,&baseline);
    assert(f.r.cls==baseline.cls && memcmp(f.r.votes,baseline.votes,sizeof f.r.votes)==0);
    /* Recompute the PCM spectrum after the baseline consistency check. */
    dia_classify_audio(copy,40000,25.0,&f.r);
    assert(f.r.cls>=1 && f.r.cls<=CLF_N_CLASS);
    {int sum=0;for(i=0;i<CLF_N_CLASS;i++)sum+=f.r.votes[i];assert(sum==CLF_N_TREE);}
    f.r.grid=(int)f.audio.desc.target_grid;f.r.grid_w=16;
    f.dir_ok=(uint32_t)out_split_grid(f.r.grid,16,&f.r.gx,&f.r.gy);
    f.r.azim_pct=out_azim_pct(f.r.gy,16);
    f.audio.valid=1;f.audio.shaft_millihz=25000;das_export_plots(copy,&f.audio);
    {unsigned peakbin=0;for(i=1;i<DAS_PLOT_N;i++)if(f.audio.envelope[i]>f.audio.envelope[peakbin])peakbin=i;
     assert(f.audio.envelope[peakbin]==1000 && peakbin>0);}
    ipc_reset(&ipc);ipc_publish(&ipc,&f);assert(ipc_consume(&ipc,&received,&cursor));
    assert(memcmp(&f,&received,sizeof f)==0);
    ui_status_clear(&status);ui_status_put(&status,&received.r,1,0,1);
    status.audio=received.audio;status.input_mode=1;status.received_blocks=79;
    assert(ui_json(json,sizeof json,&status)>0);
    assert(strstr(json,"\"first_sample\":\"0\"") && strstr(json,"\"envelope\":["));
    assert(strlen(UI_PAGE_HTML)<UI_BODY_MAX);
    file=fopen("build/gui_status.json","wb");assert(file);fputs(json,file);fclose(file);
    status.have_result=0;status.input_mode=2;status.input_error=DAS_UNSUPPORTED;
    assert(ui_json(json,sizeof json,&status)>0 && strstr(json,"\"input_error\":-1"));
    assert(ui_json(json,32,&status)<0);
    /* A 512-point block can straddle a dynamic-scene boundary. */
    for(i=0;i<DAS_AUDIO_SEGMENT;i++){source[i]=0.25;copy[i]=-0.25;}
    das_replay_dynamic_block(source,copy,DAS_AUDIO_SEGMENT,0,159900,&b);
    for(i=0;i<512;i++)assert(b.pcm[i]==(i<100?8192:-8192));
    assert(b.desc.flags==DAS_FLAG_SYNTHETIC && b.desc.first_sample==159900);
    puts("DAS_PIPELINE_PASS: replay PCM -> segment -> DSP -> classifier -> metadata/plots -> IPC -> JSON");
    return 0;
}
