#include <stdint.h>
#define CAP(i) (*(volatile uint32_t *)(0xC000u+4u*(i)))
#define RES(i) (*(volatile uint32_t *)(0x2800u+4u*(i)))
#define MAILBOX (*(volatile uint32_t *)0x4000u)
/* Stage 1: raw snapshot levels only; DAS runs independently at fixed zero delay. */
int main(void)
{
    uint32_t seq=0;
    CAP(0)=1;CAP(2)=512;
    RES(0)=0xDA516001u;RES(3)=0;RES(88)=0;RES(89)=0;
    MAILBOX=0xDA500001u;
    for(;;){
        CAP(0)=7;
        unsigned polls;
        for(polls=0;polls<1000000;polls++)if((CAP(1)&3u)==3u)break;
        if(polls==1000000){RES(3)=1;MAILBOX=0xDA5F0001u;break;}
        CAP(3)=0;uint32_t first=CAP(5),bank_seq=CAP(4);
        CAP(3)=1;
        if(CAP(5)-first!=512 || CAP(4)-bank_seq!=1){RES(3)=2;MAILBOX=0xDA5F0002u;break;}
        RES(88)=++seq;
        for(unsigned ch=0;ch<16;ch++){
            int32_t sum=0;uint64_t energy=0;uint32_t peak=0,clips=0;
            for(unsigned bank=0;bank<2;bank++){
                CAP(3)=bank;
                for(unsigned n=0;n<512;n++){
                    CAP(7)=8*n+(ch>>1);
                    /* INDEX is registered; wait for the synchronous RAM read. */
                    (void)CAP(1);
                    int32_t v=(int16_t)(CAP(8)>>(16*(ch&1)));
                    uint32_t a=v<0?(uint32_t)-v:(uint32_t)v;
                    sum+=v;energy+=(uint32_t)(v*v);
                    if(a>peak)peak=a;
                    if(v==32767 || v==-32768)clips++;
                }
            }
            RES(8+ch*5)=(uint32_t)sum;RES(9+ch*5)=(uint32_t)energy;
            RES(10+ch*5)=(uint32_t)(energy>>32);RES(11+ch*5)=peak;RES(12+ch*5)=clips;
        }
        RES(88)=++seq;RES(89)=0x4D493136u;
    }
    for(;;){}
}
