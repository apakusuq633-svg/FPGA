#include <stdio.h>
#include "fw_srp.h"
int main(void) {
    static const int a[4]={0,0,0,1},b[4]={1,2,3,3};
    int16_t tau[SRP_GRID_N];
    FILE *f=fopen("build/das4/srp_tau_host.bin","wb");
    if(!f)return 1;
    srp_init();
    for(int p=0;p<4;p++) {
        srp_dump_tau(a[p],b[p],tau);
        if(fwrite(tau,sizeof(tau),1,f)!=1)return 2;
    }
    if(fclose(f)!=0)return 3;
    f=fopen("build/das4/steer_tau_host.bin","wb");
    if(!f)return 4;
    for(int ch=0;ch<8;ch++) {
        srp_dump_tau(0,ch,tau);
        for(int g=0;g<SRP_GRID_N;g++)tau[g]=(int16_t)((uint16_t)tau[g]&16383u);
        if(fwrite(tau,sizeof(tau),1,f)!=1)return 5;
    }
    return fclose(f)!=0;
}
