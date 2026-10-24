#include "circular9_candidates.h"
#include "circular9_decimator.h"
#include <string.h>
static int16_t clip(int64_t x){return x>32767?32767:x< -32768?-32768:(int16_t)x;}
static int64_t floor15(int64_t x){return x>=0?x/32768:-((-x+32767)/32768);}
void c9_history_init(c9_history *s){s->end=s->count=0;s->epoch=0;}
void c9_history_push(c9_history *s,const uint32_t w[16]){
 uint32_t seq=w[1];
 if(s->count&&(seq!=s->end||w[14]!=s->epoch))s->count=0;
 c9_history_frame *f=&s->frames[seq%C9_HISTORY_FRAMES];
 for(unsigned i=0;i<9;i++)f->pcm[i]=(int16_t)(uint16_t)(w[8+i/2]>>(16*(i&1)));
 f->pcm[9]=0;__sync_synchronize();f->sequence=seq;__sync_synchronize();
 s->epoch=w[14];if(s->count<C9_HISTORY_FRAMES)s->count++;s->end=seq+1;
}
int c9_history_snapshot(const c9_history *s,int16_t (*pcm)[9],uint32_t *first,uint32_t *epoch){
 uint32_t end=s->end,count=s->count,e=s->epoch,aligned=end&~3u;
 if(count<C9_SNAPSHOT_FRAMES+3)return 0;
 uint32_t start=aligned-C9_SNAPSHOT_FRAMES;
 for(unsigned i=0;i<C9_SNAPSHOT_FRAMES;i++){
  const c9_history_frame *f=&s->frames[(start+i)%C9_HISTORY_FRAMES];
  if(f->sequence!=start+i)return 0;
  __sync_synchronize();for(unsigned ch=0;ch<9;ch++)pcm[i][ch]=f->pcm[ch];
  __sync_synchronize();if(f->sequence!=start+i)return 0;
 }
 if(s->epoch!=e||(uint32_t)(s->end-start)>C9_HISTORY_FRAMES||s->count<C9_SNAPSHOT_FRAMES)return 0;
 *first=start;*epoch=e;return 1;
}
unsigned c9_candidates_extract(const int32_t p[1024],c9_candidate out[3]){
 unsigned count=0;
 for(unsigned k=0;k<3;k++){
  int32_t best=0;unsigned chosen=0;
  for(unsigned g=0;g<1024;g++){
   if(p[g]<=best)continue;
   unsigned x=g%32,y=g/32;int separated=1;
   for(unsigned j=0;j<count;j++){
    int dx=(int)x-(int)(out[j].grid%32),dy=(int)y-(int)(out[j].grid/32);
    if(dx*dx+dy*dy<64)separated=0;
   }
   if(!separated)continue;
   int peak=1;
   for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
    int xx=(int)x+dx,yy=(int)y+dy;
    if(xx>=0&&xx<32&&yy>=0&&yy<32&&p[yy*32+xx]>p[g])peak=0;
   }
   if(peak){best=p[g];chosen=g;}
  }
  if(!best||(count&&(int64_t)best*5<out[0].score))break;
  out[count++]=(c9_candidate){chosen,best};
 }
 return count;
}
void c9_candidate_audio(const int16_t (*raw)[9],unsigned grid,const uint32_t *lut,
 const uint32_t fir[32],int16_t *work,double out[40000]){
 int tau[9],minimum=0,coef[9][4];unsigned age[9];int16_t history[32]={0};
 for(unsigned ch=0;ch<9;ch++){int q=lut[ch*1024+grid]&16383u;if(q&8192)q-=16384;tau[ch]=q;if(q<minimum)minimum=q;}
 for(unsigned ch=0;ch<9;ch++){
  unsigned d=(unsigned)(tau[ch]-minimum);age[ch]=d/16;int f=d&15;
  coef[ch][0]=-2*f*(16-f)*(32-f)/3;coef[ch][1]=2*(16+f)*(16-f)*(32-f);
  coef[ch][2]=2*(16+f)*f*(32-f);coef[ch][3]=-2*(16+f)*f*(16-f)/3;
 }
 for(unsigned n=0;n<C9_SNAPSHOT_FRAMES;n++){
  int32_t sum=0;
  for(unsigned ch=0;ch<9;ch++){
   int64_t v=0;for(unsigned j=0;j<4;j++)if(n>=age[ch]+j)v+=(int32_t)raw[n-age[ch]-j][ch]*coef[ch][j];
   sum+=clip(v>=0?(v+8192)/16384:-((-v+8192)/16384));
  }
  history[n&31u]=(int16_t)(sum>=0?(sum+4)/9:-((-sum+4)/9));
  int64_t v=0;for(unsigned j=0;j<32;j++)v+=(int32_t)history[(n-j)&31u]*(int16_t)(uint16_t)fir[j];
  work[n]=clip(floor15(v));
 }
 for(unsigned k=0;k<40000;k++){
  unsigned n=256+4*k+3;int64_t v=0;
  for(unsigned j=0;j<127;j++)v+=(int32_t)work[n-j]*c9_decim_coeff[j];
  out[k]=(double)clip(v>=0?(v+16384)/32768:-((-v+16384)/32768))/32768.0;
 }
}
