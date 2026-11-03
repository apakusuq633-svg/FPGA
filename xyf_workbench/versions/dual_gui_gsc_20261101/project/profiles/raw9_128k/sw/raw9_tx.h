#ifndef RAW9_TX_H
#define RAW9_TX_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#define RAW9_TX_BLOCKS 8u
#define RAW9_TX_BLOCK_BYTES (18u*1024u)
typedef struct {uint32_t first,count;uint8_t pcm[RAW9_TX_BLOCK_BYTES];} raw9_tx_block;
typedef struct {raw9_tx_block blocks[RAW9_TX_BLOCKS];uint32_t head,tail,offset,peak,retries,sent,full;} raw9_tx;
typedef int (*raw9_tx_send)(void*,uint32_t,unsigned,const uint8_t*);
static int raw9_tx_push(raw9_tx*q,uint32_t first,const uint8_t*p,size_t bytes){
 if(!bytes||bytes%18||bytes>RAW9_TX_BLOCK_BYTES)return -1;
 if(q->head-q->tail==RAW9_TX_BLOCKS){q->full++;return 0;}
 raw9_tx_block*b=&q->blocks[q->head%RAW9_TX_BLOCKS];b->first=first;b->count=(uint32_t)bytes/18;
 memcpy(b->pcm,p,bytes);q->head++;
 if(q->head-q->tail>q->peak)q->peak=q->head-q->tail;
 return 1;
}
static int raw9_tx_pump(raw9_tx*q,raw9_tx_send send,void*ctx){
 if(q->head==q->tail)return 0;
 raw9_tx_block*b=&q->blocks[q->tail%RAW9_TX_BLOCKS];unsigned n=b->count-q->offset;if(n>64)n=64;
 if(!send(ctx,b->first+q->offset,n,b->pcm+18*q->offset)){q->retries++;return 0;}
 q->sent+=n;q->offset+=n;
 if(q->offset==b->count){q->offset=0;q->tail++;}
 return 1;
}
#endif
