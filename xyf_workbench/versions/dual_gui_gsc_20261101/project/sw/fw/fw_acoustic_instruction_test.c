#include <stdint.h>
#define R(i) (*(volatile uint32_t *)(0x2800u+4u*(i)))
static uint32_t cycle(void){uint32_t c;__asm__ volatile("rdcycle %0":"=r"(c));return c;}
int main(void)
{
    R(0)=0xac100001u;uint32_t start=cycle();
    for(unsigned i=0;i<208;i++) {
        uint32_t word=i==0?256u:i==1?0x01000000u:0u;
        __asm__ volatile(".insn r 0x0b, 4, 0x40, x0, %0, x0" ::"r"(word));
    }
    for(unsigned i=0;i<208;i++) {
        uint32_t word=i==0?128u:i==1?0x80000000u:0u;
        __asm__ volatile(".insn r 0x0b, 5, 0x40, x0, %0, x0" ::"r"(word));
    }
    __asm__ volatile(".insn r 0x0b, 6, 0, x0, x0, x0");
    for(unsigned i=0;i<208;i++) {
        uint32_t word;__asm__ volatile(".insn r 0x0b, 6, 0x40, %0, x0, x0":"=r"(word));
        if(i<2)R(i+1)=word;
    }
    __asm__ volatile(".insn r 0x0b, 5, 0, x0, x0, x0");
    for(unsigned i=0;i<208;i++) {
        uint32_t word;__asm__ volatile(".insn r 0x0b, 6, 0x40, %0, x0, x0":"=r"(word));
        if(i<2)R(i+3)=word;
    }
    R(5)=cycle()-start;R(0)=0xac100002u;for(;;){}
}
