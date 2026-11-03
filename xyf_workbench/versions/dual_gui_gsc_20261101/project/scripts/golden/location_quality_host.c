#include "fw_location_quality.h"
uint32_t location_prepare_host(int16_t *x,unsigned n) {return location_prepare(x,n);}
uint32_t location_quality_host(const int32_t *p,unsigned w,unsigned pairs,unsigned grid,
                               uint32_t *contrast,int32_t *nonlocal)
{return location_map_reason(p,w,pairs,grid,contrast,nonlocal);}
uint32_t location_input_host(int32_t sum,uint64_t energy,uint32_t clipped)
{return location_input_reason(sum,energy,clipped);}
