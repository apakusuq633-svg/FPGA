#ifndef CIRCULAR9_HTTP_ARGS_H
#define CIRCULAR9_HTTP_ARGS_H
#include <stdint.h>
/* No sign, empty value, trailing query, overflow or scanf unsigned wrapping. */
static inline int c9_http_decimal(const char *p,uint32_t low,uint32_t high,uint32_t *out){
 if(!p||!out||low>high||*p<'0'||*p>'9')return 0;
 uint32_t value=0;
 do{
  unsigned digit=(unsigned)(*p-'0');
  if(digit>high||value>(high-digit)/10u)return 0;
  value=value*10u+digit;++p;
 }while(*p>='0'&&*p<='9');
 if(*p!=' '||value<low)return 0;
 *out=value;return 1;
}
#endif
