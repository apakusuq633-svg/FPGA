#ifndef CIRCULAR9_ENVELOPE_H
#define CIRCULAR9_ENVELOPE_H
/* C9F2 only. Do not alter the archived ps_features.h / 6205 feature contract.
 * 39062.5Hz x 40000 -> analytic band-select FIR /4 -> |z| -> AA FIR /4
 * -> 2500 observed envelope samples -> one 4096 point zero-padded FFT.
 * Nominal carrier band 2200..4600Hz has smooth Blackman FIR transitions.
 * This fixed engineering band needs real acoustic-bearing validation; it is not
 * a claim that this is the measured resonance band of every 6004 bearing.
 * Symmetric reflection supplies FIR edges; Hann downweights these edges.
 * Static workspace: only the PS diagnostic worker may call this extractor.
 */
#include "circular9_diagnosis.h"
#include "bearing_6004_2zr.h"
#include <float.h>
#include <string.h>
#define PS_ENV_PIPELINE_MATH_ONLY 1
#define FFT_N 4096
#include "ps_env_pipeline.h"
#define C9_ENV_INPUT_RATE 39062.5
#define C9_ENV_ANALYTIC_HALF 128u
#define C9_ENV_AA_HALF 64u
#define C9_ENV_ANALYTIC_SAMPLES 10000u
#define C9_ENV_SAMPLES 2500u
#define C9_ENV_RATE (C9_ENV_INPUT_RATE/16.0)
#define C9_ENV_FFT 4096u
#define C9_ENV_BINS (C9_ENV_FFT/2u+1u)
static double c9_env_pad[C9_DIAG_SAMPLES+2*C9_ENV_ANALYTIC_HALF];
static double c9_env_analytic[C9_ENV_ANALYTIC_SAMPLES+2*C9_ENV_AA_HALF];
static double c9_env_re[C9_ENV_FFT],c9_env_im[C9_ENV_FFT];
static double c9_env_spectrum[C9_ENV_BINS],c9_env_window[C9_ENV_SAMPLES];
static double c9_env_hi[C9_ENV_ANALYTIC_HALF+1],c9_env_hq[C9_ENV_ANALYTIC_HALF+1];
static double c9_env_aa[C9_ENV_AA_HALF+1],c9_env_window_sum;
static int c9_env_ready;

static int c9_env_finite(double x) { return x==x && x<=DBL_MAX && x>=-DBL_MAX; }
static double c9_env_blackman(unsigned k,unsigned half) {
 double s,c,s2,c2;
 d_sincos(3.14159265358979323846*(double)k/half,&s,&c);
 d_sincos(6.28318530717958647693*(double)k/half,&s2,&c2);
 return .42+.5*c+.08*c2;
}
static double c9_env_lowpass(unsigned k,unsigned half,double cutoff,double fs) {
 double s,c;
 if(!k)return 2.0*cutoff/fs;
 d_sincos(6.28318530717958647693*cutoff*k/fs,&s,&c);
 return s/(3.14159265358979323846*k)*c9_env_blackman(k,half);
}
static void c9_env_setup(void) {
 /* Shared no-libm math also declares an inverse FFT; this pipeline needs forward only. */
 (void)fft_inv;
 double sum=0.0,dc_gain=0.0;
 for(unsigned k=0;k<=C9_ENV_ANALYTIC_HALF;k++) {
  double half_band=.5*(C9_DIAG_CARRIER_HIGH_HZ-C9_DIAG_CARRIER_LOW_HZ);
  double center=.5*(C9_DIAG_CARRIER_HIGH_HZ+C9_DIAG_CARRIER_LOW_HZ);
  double s,c,h=c9_env_lowpass(k,C9_ENV_ANALYTIC_HALF,half_band,C9_ENV_INPUT_RATE);
  d_sincos(6.28318530717958647693*center*k/C9_ENV_INPUT_RATE,&s,&c);
  c9_env_hi[k]=2*h*c;c9_env_hq[k]=2*h*s;
  dc_gain+=c9_env_hi[k]*(k?2.0:1.0);
 }
 /* An exact DC zero prevents a constant input from masquerading as carrier energy. */
 c9_env_hi[0]-=dc_gain;
 for(unsigned k=0;k<=C9_ENV_AA_HALF;k++) {
  c9_env_aa[k]=c9_env_lowpass(k,C9_ENV_AA_HALF,900.0,C9_ENV_INPUT_RATE/4.0);
  sum+=c9_env_aa[k]*(k?2.0:1.0);
 }
 for(unsigned k=0;k<=C9_ENV_AA_HALF;k++)c9_env_aa[k]/=sum;
 c9_env_window_sum=0.0;
 for(unsigned i=0;i<C9_ENV_SAMPLES;i++) {
  double s,c;d_sincos(6.28318530717958647693*i/(C9_ENV_SAMPLES-1u),&s,&c);
  c9_env_window[i]=.5-.5*c;c9_env_window_sum+=c9_env_window[i];
 }
 twiddle_build(C9_ENV_FFT);c9_env_ready=1;
}
static double c9_env_peak(double f0) {
 /* Engineering search: max(one record reciprocal,1%target frequency).
  * This tolerance is not a speed estimator or verified bearing-slip model.
  * DC is always excluded, including at the 600rpm FTF (~3.976Hz). */
 const double df=C9_ENV_RATE/C9_ENV_FFT;
 double radius=C9_DIAG_ORDER_TOLERANCE_FRACTION*f0;
 if(radius<C9_DIAG_ORDER_MINIMUM_HALF_WIDTH_HZ)radius=C9_DIAG_ORDER_MINIMUM_HALF_WIDTH_HZ;
 unsigned a=(unsigned)((f0-radius)/df+1.0),z=(unsigned)((f0+radius)/df);
 if(a<1u)a=1u;
 if(z>=C9_ENV_BINS)z=C9_ENV_BINS-1u;
 double peak=0.0;
 for(unsigned i=a;i<=z;i++)if(c9_env_spectrum[i]>peak)peak=c9_env_spectrum[i];
 return peak;
}
static void c9_env_normalize(double v[18],double carrier) {
 double sorted[18],floor=carrier*1e-8+2.220446049250313e-16;
 memcpy(sorted,v,sizeof(sorted));
 for(unsigned i=1;i<18;i++) {
  double key=sorted[i];unsigned j=i;
  while(j && sorted[j-1]>key){sorted[j]=sorted[j-1];j--;}
  sorted[j]=key;
 }
 double median=.5*(sorted[8]+sorted[9]);
 for(unsigned i=0;i<18;i++)v[i]=20*d_log10((v[i]+floor)/(median+floor));
}
static int c9_env_extract(const double *x,double shaft,double v[18],c9_diag_extraction *meta) {
 if(!meta || !v)return 0;
 memset(meta,0,sizeof(*meta));memset(v,0,18*sizeof(*v));
 meta->status=C9_DIAG_EXTRACT_BAD_INPUT;
 if(!x || !c9_env_finite(shaft) || shaft<10 || shaft>30)return 0;
 double input_energy=0.0;
 for(unsigned i=0;i<C9_DIAG_SAMPLES;i++) {
  if(!c9_env_finite(x[i]) || x[i]<-1 || x[i]>1)return 0;
  input_energy+=x[i]*x[i];
 }
 if(!c9_env_ready)c9_env_setup();
 memcpy(c9_env_pad+C9_ENV_ANALYTIC_HALF,x,C9_DIAG_SAMPLES*sizeof(*x));
 for(unsigned i=0;i<C9_ENV_ANALYTIC_HALF;i++) {
  c9_env_pad[C9_ENV_ANALYTIC_HALF-1u-i]=x[i+1u];
  c9_env_pad[C9_ENV_ANALYTIC_HALF+C9_DIAG_SAMPLES+i]=x[C9_DIAG_SAMPLES-2u-i];
 }
 double band_energy=0.0;
 for(unsigned i=0;i<C9_ENV_ANALYTIC_SAMPLES;i++) {
  const double *p=c9_env_pad+C9_ENV_ANALYTIC_HALF+4u*i;
  double re=c9_env_hi[0]*p[0],im=0.0;
  /* Even in-phase / odd quadrature coefficients halve FIR multiplications. */
  for(unsigned k=1;k<=C9_ENV_ANALYTIC_HALF;k++) {
   double left=p[-(int)k],right=p[k];
   re+=c9_env_hi[k]*(left+right);im+=c9_env_hq[k]*(left-right);
  }
  double power=re*re+im*im;
  c9_env_analytic[C9_ENV_AA_HALF+i]=d_sqrt(power);band_energy+=power;
 }
 for(unsigned i=0;i<C9_ENV_AA_HALF;i++) {
  c9_env_analytic[C9_ENV_AA_HALF-1u-i]=c9_env_analytic[C9_ENV_AA_HALF+i+1u];
  c9_env_analytic[C9_ENV_AA_HALF+C9_ENV_ANALYTIC_SAMPLES+i]=
   c9_env_analytic[C9_ENV_AA_HALF+C9_ENV_ANALYTIC_SAMPLES-2u-i];
 }
 double mean=0.0;
 for(unsigned i=0;i<C9_ENV_SAMPLES;i++) {
  const double *p=c9_env_analytic+C9_ENV_AA_HALF+4u*i;
  double value=c9_env_aa[0]*p[0];
  for(unsigned k=1;k<=C9_ENV_AA_HALF;k++)value+=c9_env_aa[k]*(p[-(int)k]+p[k]);
  c9_env_re[i]=value;mean+=value*c9_env_window[i];
 }
 mean/=c9_env_window_sum;
 double modulation_energy=0.0;
 for(unsigned i=0;i<C9_ENV_SAMPLES;i++) {
  double centered=c9_env_re[i]-mean;
  modulation_energy+=centered*centered*c9_env_window[i];
  c9_env_re[i]=centered*c9_env_window[i];
 }
 memset(c9_env_re+C9_ENV_SAMPLES,0,(C9_ENV_FFT-C9_ENV_SAMPLES)*sizeof(double));
 memset(c9_env_im,0,sizeof(c9_env_im));
 fft_core(c9_env_re,c9_env_im,C9_ENV_FFT);
 for(unsigned i=0;i<C9_ENV_BINS;i++)
  c9_env_spectrum[i]=2*d_hypot(c9_env_re[i],c9_env_im[i])/c9_env_window_sum;
 for(unsigned o=0;o<4;o++)for(unsigned h=1;h<=4;h++)
  v[4u*o+h-1u]=c9_env_peak(h*bearing6004_orders[o]*shaft);
 v[16]=c9_env_peak(shaft);v[17]=c9_env_peak(2*shaft);
 meta->carrier_rms=d_sqrt(band_energy/(2.0*C9_ENV_ANALYTIC_SAMPLES));
 meta->modulation_rms=d_sqrt(modulation_energy/c9_env_window_sum);
 c9_env_normalize(v,meta->carrier_rms);
 meta->status=meta->carrier_rms<d_sqrt(input_energy/C9_DIAG_SAMPLES)*1e-4+1e-10?C9_DIAG_EXTRACT_NO_CARRIER:
  meta->modulation_rms<mean*1e-4+1e-10?C9_DIAG_EXTRACT_NO_MODULATION:C9_DIAG_EXTRACT_OK;
 meta->envelope_samples=C9_ENV_SAMPLES;meta->fft_size=C9_ENV_FFT;meta->fft_count=1;
 meta->fir_multiplications=C9_ENV_ANALYTIC_SAMPLES*(1u+2u*C9_ENV_ANALYTIC_HALF)+
  C9_ENV_SAMPLES*(1u+C9_ENV_AA_HALF);
 meta->observation_seconds=C9_DIAG_SAMPLES/C9_ENV_INPUT_RATE;
 meta->envelope_rate_hz=C9_ENV_RATE;meta->bin_spacing_hz=C9_ENV_RATE/C9_ENV_FFT;
 meta->hann_enbw_hz=1.5*C9_ENV_RATE/(C9_ENV_SAMPLES-1u);
 meta->hann_first_null_hz=2*C9_ENV_RATE/(C9_ENV_SAMPLES-1u);
 meta->carrier_low_hz=C9_DIAG_CARRIER_LOW_HZ;meta->carrier_high_hz=C9_DIAG_CARRIER_HIGH_HZ;
 meta->carrier_transition_guard_hz=C9_DIAG_CARRIER_TRANSITION_GUARD_HZ;
 meta->envelope_lowpass_hz=900;
 return 1;
}
#endif
