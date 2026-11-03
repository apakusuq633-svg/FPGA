/* Native batch runner removes Python/FFI overhead from host throughput numbers. */
#include "../sw/gsc12.h"
void gsc12_run_packets(gsc12_state *s,const uint32_t *packets,size_t n,
                      int enabled,int freeze,int16_t *out,uint32_t *model) {
 for(size_t i=0;i<n;i++) {
   out[i]=gsc12_process(s,packets+16*i,enabled,freeze);
   if(model)model[i]=gsc12_model_beam(s);
 }
}
