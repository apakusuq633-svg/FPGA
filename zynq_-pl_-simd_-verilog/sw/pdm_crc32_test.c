#include <assert.h>
#include <stdio.h>
#include <time.h>
#include "pdm_stream.h"

/* Independent slow polynomial reference; never linked into production. */
uint32_t crc32_bitwise_reference(const uint8_t *p,size_t n)
{
 uint32_t c=~0u;
 for(size_t i=0;i<n;i++) {
  c^=p[i];
  for(unsigned k=0;k<8;k++)c=(c>>1)^((c&1u)?0xedb88320u:0u);
 }
 return ~c;
}
/* Exact previous production implementation, retained only for comparison. */
uint32_t crc32_nibble_reference(const uint8_t *p,size_t n)
{
 static const uint32_t table[16]={0x00000000,0x1db71064,0x3b6e20c8,0x26d930ac,
  0x76dc4190,0x6b6b51f4,0x4db26158,0x5005713c,0xedb88320,0xf00f9344,0xd6d6a3e8,
  0xcb61b38c,0x9b64c2b0,0x86d3d2d4,0xa00ae278,0xbdbdf21c};
 uint32_t c=~0u;
 for(size_t i=0;i<n;i++){c^=p[i];c=(c>>4)^table[c&15];c=(c>>4)^table[c&15];}
 return ~c;
}
typedef uint32_t (*crc_function)(const uint8_t *,size_t);
static volatile uint32_t sink;
int main(void)
{
 crc_function functions[3]={crc32_bitwise_reference,crc32_nibble_reference,pdm_crc32};
 const char *names[3]={"bitwise_reference","previous_nibble","byte_table"};
 uint8_t data[4096];uint32_t rng=0x20261023u;
 for(unsigned i=0;i<sizeof(data);i++){rng=1664525u*rng+1013904223u;data[i]=(uint8_t)(rng>>24);}
 const size_t lengths[3]={120,1120,4096};
 for(unsigned k=0;k<3;k++) {
  assert(functions[k]((const uint8_t *)"123456789",9)==0xcbf43926u);
  assert(functions[k](NULL,0)==0u);
 }
 puts("[");
 for(unsigned n=0;n<3;n++)for(unsigned k=0;k<3;k++)for(unsigned rep=0;rep<3;rep++) {
  /* Volatile indirect call prevents folding repeated identical inputs. */
  crc_function volatile function=functions[k];
  unsigned iterations=(unsigned)(16u*1024u*1024u/lengths[n]);
  clock_t begin=clock();uint32_t accumulated=0;
  for(unsigned i=0;i<iterations;i++)accumulated^=function(data,lengths[n])+i;
  double seconds=(double)(clock()-begin)/CLOCKS_PER_SEC;sink=accumulated;
  printf("{\"implementation\":\"%s\",\"bytes\":%u,\"iterations\":%u,\"repeat\":%u,\"host_clock_seconds\":%.9f}%s\n",
   names[k],(unsigned)lengths[n],iterations,rep,seconds,n==2&&k==2&&rep==2?"":",");
 }
 puts("]");return 0;
}
