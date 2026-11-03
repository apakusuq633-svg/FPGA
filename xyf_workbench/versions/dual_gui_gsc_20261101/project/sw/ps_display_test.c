#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "ps_das_plots.h"
static double x[40000],legacy[PS_FEAT_NBIN];
static das_audio_report report;
int main(void) {
    double old,low=0,peak=0;unsigned best=0;
    fea_setup(39062.5,1400,4600);
    for(unsigned i=0;i<40000;i++)x[i]=0.3+0.2*sin(6.283185307179586*419*i/8192.0);
    fea_env_spectrum(x,40000,legacy,0);old=legacy[1];
    fea_env_spectrum_mode(x,40000,fea_acc,0,1);
    for(unsigned i=0;i<4;i++)if(fea_acc[i]>low)low=fea_acc[i];
    assert(low<old*0.001);
    report.desc.sample_count=40000;das_export_plots(x,&report);
    for(unsigned i=0;i<DAS_PLOT_N;i++)assert(report.envelope[i]==0);
    assert(report.spectrum_dc_ppm>299900 && report.spectrum_dc_ppm<300100);
    assert(report.rms_ppm>331000 && report.rms_ppm<332000 && !report.clipped_samples);
    assert(report.spectrum[0]<5);
    for(unsigned i=0;i<40000;i++)x[i]=0.2*(1+0.5*sin(6.283185307179586*21*i/8192.0))*sin(6.283185307179586*419*i/8192.0);
    fea_env_spectrum_mode(x,40000,fea_acc,0,1);
    for(unsigned i=1;i<128;i++)if(fea_acc[i]>peak){peak=fea_acc[i];best=i;}
    assert(best==21 && fea_acc[0]<peak*0.0001);
    for(unsigned i=0;i<40000;i++)x[i]=1.0;
    das_export_plots(x,&report);
    assert(report.clipped_samples==40000 && report.mean_ppm==1000000 && report.peak_ppm==1000000);
    for(unsigned i=0;i<DAS_PLOT_N;i++)assert(report.envelope[i]==0 && report.spectrum[i]==0);
    printf("DISPLAY_DSP_PASS legacy_low=%.9g corrected_low=%.9g reduction=%.3g AM_peak_bin=%u clipping=40000\n",old,low,old/low,best);
    return 0;
}
