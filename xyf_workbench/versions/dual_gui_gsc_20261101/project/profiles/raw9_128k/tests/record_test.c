#include "raw9_record.h"
#include "pdm_stream.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static unsigned bytes;static int mode;
static int sink(void*c,const uint8_t*p,size_t n){(void)c;
 for(unsigned k=0;k<n/18;k++)for(unsigned ch=0;ch<9;ch++){
  short got=(short)((unsigned)p[18*k+2*ch]|(unsigned)p[18*k+2*ch+1]<<8);
  assert(got==(short)(bytes/18+k-ch));}
 if(mode)return mode==1?0:-1;
 bytes+=(unsigned)n;return 1;}
static void put(uint8_t*p,unsigned x){for(int i=0;i<4;i++)p[i]=(uint8_t)(x>>(8*i));}
static void slot(uint8_t*p,unsigned n){memset(p,0,128);put(p,0x47534302);put(p+4,n);put(p+52,0x000a0009);
 put(p+64,(unsigned)((uint64_t)n*625/2));put(p+72,n);put(p+80,0x394d4450);put(p+84,128);put(p+92,0x00100009);
 for(int c=0;c<9;c++){short x=(short)(n-c);p[32+2*c]=(uint8_t)x;p[33+2*c]=(uint8_t)(x>>8);}
 put(p+120,pdm_crc32(p,120));put(p+124,~n);}
int main(void){raw9_record r;uint8_t p[128];raw9_init(&r,sink,0);
 for(unsigned n=0;n<RAW9_FRAMES;n++){slot(p,n);assert(raw9_feed(&r,p)==1);}
 assert(raw9_flush(&r)==1&&r.complete&&bytes==RAW9_BYTES);
 raw9_init(&r,sink,0);slot(p,0);assert(raw9_feed(&r,p)==1);slot(p,2);assert(raw9_feed(&r,p)<0&&r.gap_count);
 bytes=0;raw9_init(&r,sink,0);slot(p,0);assert(raw9_feed(&r,p)==1);mode=2;assert(raw9_flush(&r)<0&&r.write_errors);
 mode=1;raw9_init(&r,sink,0);for(unsigned n=0;n<=1024;n++){slot(p,n);int rc=raw9_feed(&r,p);if(n==1024)assert(rc<0&&r.overflow_count);else assert(rc==1);}
 puts("RAW9_RECORD_PASS frames=3840000 bytes=69120000 gap/write/backpressure tested");}
