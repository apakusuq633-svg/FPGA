/* Display envelope uses untapered band extraction, then weighted DC removal and Hann. */
#ifndef PS_DAS_PLOTS_H
#define PS_DAS_PLOTS_H
#include "ps_features.h"
#include "ps_das_report.h"
static inline void das_plot_normalize(const double *v,uint32_t *out)
{
    unsigned i;double max=0;
    for(i=0;i<DAS_PLOT_N;i++) if(v[i]>max) max=v[i];
    /* Never magnify FFT roundoff into a full-height plot for constant signals. */
    for(i=0;i<DAS_PLOT_N;i++) out[i]=max>1e-9?(uint32_t)(1000.0*v[i]/max):0u;
}
static inline void das_export_plots(const double *x,das_audio_report *r)
{
    double values[DAS_PLOT_N],sum=0,energy=0,peak=0,wm=0,ws=0;unsigned i,j;
    r->clipped_samples=0;
    for(i=0;i<r->desc.sample_count;i++) {
        double v=x[i],a=v<0?-v:v;
        sum+=v;energy+=v*v;if(a>peak)peak=a;
        if(v>=32767.0/32768.0 || v<=-1.0)r->clipped_samples++;
    }
    r->mean_ppm=r->desc.sample_count?(int32_t)(sum*1000000.0/r->desc.sample_count):0;
    r->rms_ppm=r->desc.sample_count?(uint32_t)(d_sqrt(energy/r->desc.sample_count)*1000000.0):0;
    r->peak_ppm=(uint32_t)(peak*1000000.0);
    fea_env_spectrum_mode(x,(int)r->desc.sample_count,fea_acc,NULL,1);
    for(i=0;i<DAS_PLOT_N;i++) values[i]=i?fea_acc[i]:0;
    das_plot_normalize(values,r->envelope);
    for(i=0;i<PS_FEAT_NFFT;i++){wm+=x[i]*fea_w[i];ws+=fea_w[i];}
    wm/=ws;r->spectrum_dc_ppm=(uint32_t)((wm<0?-wm:wm)*1000000.0);
    for(i=0;i<PS_FEAT_NFFT;i++){fea_re[i]=(x[i]-wm)*fea_w[i];fea_im[i]=0;}
    fft_core(fea_re,fea_im,PS_FEAT_NFFT);
    for(i=0;i<DAS_PLOT_N;i++) {
        values[i]=0;
        for(j=0;j<32;j++) {
            unsigned k=i*32+j;double v=k?d_hypot(fea_re[k],fea_im[k]):0;
            if(v>values[i]) values[i]=v;
        }
    }
    das_plot_normalize(values,r->spectrum);
}
#endif
