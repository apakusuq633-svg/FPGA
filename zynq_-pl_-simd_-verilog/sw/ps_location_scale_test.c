#include <assert.h>
#include <stdio.h>
#include "fw/fw_location_scale.h"
int main(void)
{
    int16_t x[4]={30,-30,1,0};
    location_scale(x,4,30);
    assert(x[0]==15360 && x[1]==-15360 && x[2]==512 && x[3]==0);
    int16_t full[3]={32767,-32768,12};
    location_scale(full,3,32768);
    assert(full[0]==32767 && full[1]==-32768 && full[2]==12);
    int16_t silent[2]={0,0};location_scale(silent,2,0);
    assert(!silent[0] && !silent[1]);
    for(unsigned peak=1;peak<=32768;peak++) {
        int16_t v=(int16_t)-(int32_t)peak;
        location_scale(&v,1,peak);
        assert(v<=-8192);
    }
    puts("LOCATION_SCALE_PASS: quiet signal headroom, full scale, silence and all peak ranges");
}
