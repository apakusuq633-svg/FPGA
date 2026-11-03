#include "raw9_tx.h"
#include <assert.h>
#include <stdio.h>
static raw9_tx q;static unsigned expected,attempt;static uint8_t block[18*1024];
static int send(void*c,uint32_t first,unsigned n,const uint8_t*p){
 (void)c;if(++attempt%7==0)return 0;
 assert(first==expected);for(unsigned k=0;k<18*n;k++)assert(p[k]==(uint8_t)((first*18+k)%251));expected+=n;return 1;
}
int main(void){
 for(unsigned b=0;b<3750;b++){
  for(unsigned k=0;k<sizeof(block);k++)block[k]=(uint8_t)((b*sizeof(block)+k)%251);
  assert(raw9_tx_push(&q,b*1024,block,sizeof(block))==1);
  while(q.head!=q.tail)raw9_tx_pump(&q,send,0);
 }
 assert(expected==3840000&&q.sent==expected&&q.retries>0);
 memset(&q,0,sizeof(q));for(unsigned i=0;i<8;i++)assert(raw9_tx_push(&q,i*1024,block,sizeof(block))==1);
 assert(raw9_tx_push(&q,8192,block,sizeof(block))==0&&q.full==1);
 puts("RAW9_TX_PASS full30s retry-no-duplicate, full queue refusal");
}
