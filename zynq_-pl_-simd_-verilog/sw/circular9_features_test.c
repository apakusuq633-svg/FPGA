#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "ps_features.h"
#include "bearing_6004_2zr.h"
static double audio[40000];
static double measured[4096];
int main(void)
{
    double ratio=6.35/31.0,reference[4]={0.5*(1-ratio),
        31.0/(2*6.35)*(1-ratio*ratio),9.0/2*(1-ratio),9.0/2*(1+ratio)};
    for(unsigned i=0;i<4;i++)assert(fabs(reference[i]-bearing6004_orders[i])<1e-12);
    assert(!BEARING6004_MODEL_VALIDATED);
    assert(bearing6004_resolution_mask(10.0,39062.5/8192)&1u);
    assert(!(bearing6004_resolution_mask(30.0,39062.5/8192)&1u));
    // Independently specified AM signal: carrier 3kHz, outer-race modulation.
    const double rate=39062.5,modulation=9.0/2*(1-6.35/31)*10;
    for(unsigned n=0;n<40000;n++) {
        double t=n/rate;
        audio[n]=(1+0.5*cos(2*3.141592653589793*modulation*t))*sin(2*3.141592653589793*3000*t);
    }
    fea_setup(rate,1400,4600);
    double v[18];fea_frame18_orders(audio,40000,10,bearing6004_orders,v);
    for(unsigned k=0;k<4096;k++)measured[k]=fea_last_envelope[k];
    // Hann before the analytic transform itself modulates a constant carrier.
    // Subtract that independent control spectrum when locating the injected AM.
    for(unsigned n=0;n<40000;n++)audio[n]=sin(2*3.141592653589793*3000*n/rate);
    double control[18];fea_frame18_orders(audio,40000,10,bearing6004_orders,control);
    unsigned peak=1;
    for(unsigned k=2;k<100;k++)if(measured[k]-fea_last_envelope[k]>measured[peak]-fea_last_envelope[peak])peak=k;
    assert(fabs(peak*rate/8192-modulation)<rate/8192);
    assert(v[8]>control[8]*2);
    assert(v[8]>0);
    fea_norm18(v);
    for(unsigned i=0;i<18;i++)assert(isfinite(v[i]));
    puts("CIRCULAR9_FEATURES_PASS mathematical_profile_only model=UNVERIFIED");
    return 0;
}
