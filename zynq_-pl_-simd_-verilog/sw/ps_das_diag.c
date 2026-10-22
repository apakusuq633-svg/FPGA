/* One-shot FIFO commissioning: receive one full segment, stop PL, then classify.
 * Continuous acquisition belongs to the dual-core UI. Matching bitstream required. */
#include "ps_das_mmio.h"
#include "ps_das_fifo.h"
#include "ps_pl_live.h"
#include "ps_features.h"
#include "ps_classifier.h"
#include "ps_output.h"
#define RV32_DAS_BASE 0x43C00000u
#ifndef PS_DAS_WINDOW_PRESENT
#define PS_DAS_WINDOW_PRESENT 0
#endif
static das_segment_queue audio_queue; /* DDR: 2 x 40000 doubles, not OCM or DTCM */
static das_audio_block audio_block;
static das_fifo_receiver receiver;
int main(void)
{
    das_bus bus=das_axi_bus(RV32_DAS_BASE);
    uint32_t drops;
    int rc;
    /* An unmapped AXI read may cause an ARM external abort, not return zero.
     * Enable only after loading a bitstream which implements this contract. */
    if(!PS_DAS_WINDOW_PRESENT) {
        xil_printf("DAS_INTERFACE_DISABLED: build with matching PL window first\r\n");
        return 1;
    }
    if(pl_live_prepare(&bus)!=0) {
        xil_printf("DAS_INTERFACE_UNAVAILABLE: matching PL audio window required\r\n");
        return 1;
    }
    das_queue_init(&audio_queue);
    das_fifo_init(&receiver);
    fea_setup(39062.5,1400.0,4600.0);
    pl_live_start(&bus);
    for(;;) {
        das_segment *segment;
        if(bus.read(bus.ctx,0x30) || (bus.read(bus.ctx,0x34)&0xffff0000u)==0xDA5F0000u) {
            pl_live_stop(&bus);return 1;
        }
        rc=das_fifo_poll(&bus,&receiver,&audio_block,&drops);
        if(rc==DAS_EMPTY) continue;
        if(rc!=DAS_OK) {
            pl_live_stop(&bus);
            xil_printf("DAS_RECEIVE_ERROR %d; stopped without releasing invalid data\r\n",rc);
            return 1;
        }
        rc=das_queue_push(&audio_queue,&audio_block);
        if(rc<0) xil_printf("DAS_SEGMENT_RESET %d\r\n",rc);
        segment=das_queue_take(&audio_queue);
        if(segment) {
            double v[PS_FEAT_NFEAT],med;
            float x[CLF_N_FEAT];
            struct diag_result r;
            unsigned i;
            pl_live_stop(&bus); /* No FIFO overflow during the serial/DSP phase. */
            memset(&r,0,sizeof r);
            fea_frame18(segment->samples,DAS_AUDIO_SEGMENT,25.0,v);
            med=fea_norm18(v);
            for(i=0;i<CLF_N_FEAT;i++) x[i]=(float)v[i];
            r.cls=clf_predict(x,r.votes);
            if(r.cls<1 || r.cls>CLF_N_CLASS) {das_queue_release(segment);return 1;}
            r.conf_pct=100*r.votes[r.cls-1]/CLF_N_TREE;
            r.med_milli=(int)(med*1000.0);
            r.grid=-1;
            r.grid_w=0; /* FIFO does not associate steering metadata with audio. */
            (void)out_split_grid(r.grid,r.grid_w,&r.gx,&r.gy);
            r.azim_pct=out_azim_pct(r.gy,r.grid_w);
            xil_printf("DAS_AUDIO source=%s first_hi=%u first_lo=%u steer=%u flags=%u\r\n",
                (segment->desc.flags&DAS_FLAG_SYNTHETIC)?"synthetic":"live",
                (unsigned)(segment->desc.first_sample>>32),
                (unsigned)segment->desc.first_sample,(unsigned)segment->desc.steer_seq,
                (unsigned)segment->desc.flags);
            (void)out_print_diag(&r);
            out_print_human(&r);
            das_queue_release(segment);
            return 0;
        }
    }
}
