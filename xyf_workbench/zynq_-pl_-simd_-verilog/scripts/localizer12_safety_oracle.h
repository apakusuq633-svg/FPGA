// Independent host fixed-point arithmetic; no simulator RAM is used as a reference.
extern "C" {
#include "fw_fft.h"
#include "fw_gcc.h"
}
static uint32_t safety_seed=20261015;
// Optional independent physical scene vectors, interleaved signed16 channels.
static std::vector<int16_t> acoustic_pcm;
static int16_t safety_pcm(uint32_t seq,unsigned ch) {
    if(!acoustic_pcm.empty()) {
        if(uint64_t(seq)*12+ch>=acoustic_pcm.size())return 0;
        return acoustic_pcm[uint64_t(seq)*12+ch];
    }
    uint32_t x=seq*0x9e3779b9u+ch*0x85ebca6bu+safety_seed;
    x^=x>>16;x*=0x7feb352du;x^=x>>15;x*=0x846ca68bu;x^=x>>16;
    if(ch==10&&seq%113==0)return seq&1?32767:-32768;
    return int16_t(x>>16);
}
static uint32_t packed(int16_t a,int16_t b){return uint16_t(a)|(uint32_t(uint16_t(b))<<16);}
struct SafetyOracle {
    std::vector<uint32_t> prep,fft,phi,corr,scores,stats;
    SafetyOracle():prep(12288),fft(12*513),phi(66*513),corr(66*512),scores(1024),stats(60){fft_init();}
    void generate(uint32_t first,const std::vector<uint32_t>& hann,const std::vector<uint32_t>& lut) {
        int16_t spectra[12][1026],frame[1024],r[1024]={},p[1026];
        for(int ch=0;ch<12;ch++) {
            int64_t sum=0;uint64_t energy=0;unsigned peak=0,clips=0;
            for(int n=0;n<1024;n++){int x=safety_pcm(first+n,ch);sum+=x;energy+=int64_t(x)*x;peak=std::max(peak,unsigned(std::abs(x)));clips+=x==32767||x==-32768;}
            stats[ch*5]=sum;stats[ch*5+1]=energy;stats[ch*5+2]=energy>>32;stats[ch*5+3]=peak;stats[ch*5+4]=clips;
            int mean=sum/1024;unsigned bound=0,left=0,right=0;
            for(int n=0;n<1024;n++)bound=std::max(bound,unsigned(std::abs(int(safety_pcm(first+n,ch))-mean)));
            while(bound&&bound<8192&&left<14){bound*=2;left++;}
            while(bound>32767){bound=(bound+1)/2;right++;}
            for(int n=0;n<1024;n++) {
                int16_t scaled=((int(safety_pcm(first+n,ch))-mean)*int(1u<<left))>>right;
                frame[n]=(int(scaled)*int16_t(hann[n]))>>14;prep[ch*1024+n]=uint16_t(frame[n]);
            }
            fft1024(frame,spectra[ch]);
            for(int k=0;k<513;k++)fft[ch*513+k]=packed(spectra[ch][2*k],spectra[ch][2*k+1]);
        }
        int pair=0;std::fill(scores.begin(),scores.end(),0);
        for(int a=0;a<12;a++)for(int b=a+1;b<12;b++,pair++) {
            gcc_cached_ring(spectra[a],spectra[b],r);gcc_audit_phi(p);
            for(int k=0;k<513;k++)phi[pair*513+k]=packed(p[2*k],p[2*k+1]);
            for(int k=0;k<512;k++)corr[pair*512+k]=packed(r[2*k],r[2*k+1]);
            for(int g=0;g<1024;g++) {
                unsigned v=lut[pair*1024+g],k=v>>4,j=(k+1)&31;
                int x=r[k<16?k:k+992],y=r[j<16?j:j+992];
                scores[g]+=x+(((y-x)*int(v&15))>>4);
            }
        }
    }
};
