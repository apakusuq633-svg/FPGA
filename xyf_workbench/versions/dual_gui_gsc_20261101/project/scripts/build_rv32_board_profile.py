"""Emit a standalone Cortex-A9 loader/drainer; no BSP, no production geometry."""
from pathlib import Path
import json,argparse
R=Path(__file__).resolve().parents[1];O=R/'build/rv32_mem_perf/board_profile';O.mkdir(parents=True,exist_ok=True)
parser=argparse.ArgumentParser();parser.add_argument('--run',default='mem_full_chain');args=parser.parse_args()
assert args.run.replace('_','').isalnum()
FW=R/'build/pdm12_runs'/args.run/'fw'
def words(path):return [int(w,16) for w in path.read_text().split()]
def array(name,vals,typ='unsigned'):
 return f'static const {typ} {name}[{len(vals)}]={{'+','.join(hex(v) for v in vals)+'};\n'
src=array('itcm',words(FW/'itcm.hex'))+array('dtcm',words(FW/'dtcm.hex'))+array('lut',words(R/'build/pdm12_test_srp/lut.hex'),'unsigned short')
src+='''
#define REG(off) (*(volatile unsigned *)(0x43c00000u+(off)))
#define OUT ((volatile unsigned *)0xffff0000u)
static unsigned read_tcm(unsigned index){REG(0x80)=0x80000000u|index;return REG(0x88);}
void main(void){
 OUT[0]=0x42505230u;OUT[1]=0;OUT[2]=0;OUT[3]=0;OUT[4]=0;
 REG(0)=3;REG(0x80)=0;
 for(unsigned i=0;i<sizeof(itcm)/4;i++)REG(0x84)=itcm[i];
 REG(0x80)=0;
 for(unsigned i=0;i<sizeof(itcm)/4;i++)if(REG(0x88)!=itcm[i])OUT[2]++;
 REG(0x80)=0x80000000u;for(unsigned i=0;i<4096;i++)REG(0x84)=0;
 REG(0x80)=0x80000000u;for(unsigned i=0;i<sizeof(dtcm)/4;i++)REG(0x84)=dtcm[i];
 REG(0x80)=0x80000000u;
 for(unsigned i=0;i<sizeof(dtcm)/4;i++)if(REG(0x88)!=dtcm[i])OUT[2]++;
 REG(0x408)=0;for(unsigned i=0;i<sizeof(lut)/2;i++)REG(0x40c)=lut[i];
 REG(0xc0)=0x400;for(unsigned i=0;i<32;i++)REG(0xc4)=i==0?32767:0;
 if(OUT[2]){OUT[0]=0x42504641u;for(;;){}}
 REG(0x380)=5;REG(0)=1;OUT[0]=0x42505231u;
 unsigned previous=0,loop=0,last_pair=0,last_pair_frame=0;
 for(unsigned f=0;f<4;f++)for(unsigned k=245;k<256;k++)OUT[32+f*256+k]=0;
 while(previous<4 && loop++<20000000u){
  while((REG(0x384)>>3)&511u){(void)REG(0x38c);OUT[3]++;}
  unsigned pair_frame=read_tcm(0xa00+197),pair=read_tcm(0xa00+196);
  if(pair_frame>=1 && pair_frame<=4 && pair>=1 && pair<=66){
   if(pair_frame!=last_pair_frame){last_pair_frame=pair_frame;last_pair=0;}
   if(pair!=last_pair){
    volatile unsigned *p=OUT+32+(pair_frame-1)*256;
    if(pair!=last_pair+1)p[250]++;
    p[245]+=read_tcm(0xa00+198);p[246]+=read_tcm(0xa00+199);
    p[247]+=read_tcm(0xa00+201);p[248]+=read_tcm(0xa00+202);p[249]++;
    if(read_tcm(0xa00+196)!=pair)p[250]++;
    last_pair=pair;
   }
  }
  unsigned frame=read_tcm(0xa01);
  if(frame>previous){
   if(frame!=previous+1)OUT[4]++;
   volatile unsigned *row=OUT+32+previous*256;
   REG(0x80)=0x80000a00u;
   for(unsigned k=0;k<240;k++)row[k]=REG(0x88);
   row[240]=REG(0x390);row[241]=REG(0x394);row[242]=REG(0x30);row[243]=REG(0x388);row[244]=REG(0x398);
   if(read_tcm(0xa01)!=frame)OUT[4]++;
   OUT[1]=frame;previous=frame;
  }
  if(read_tcm(0xa03))break;
 }
 REG(0x380)=0;while((REG(0x384)>>3)&511u){(void)REG(0x38c);OUT[3]++;}
 REG(0)=3;
 OUT[5]=REG(0x390);OUT[6]=REG(0x30);OUT[7]=REG(0x318);
 OUT[8]=REG(0x33c);OUT[9]=REG(0x020);
 OUT[0]=previous==4 && !OUT[2] && !OUT[4] && !OUT[5] && !OUT[6]?0x42505041u:0x42504641u;
 for(;;){}
}
'''
(O/'loader.c').write_text(src)
(O/'start.S').write_text('''.syntax unified
.arm
.section .text.start,"ax"
.global _start
_start:
 cpsid if
 mrc p15,0,r0,c1,c0,0
 bic r0,r0,#1
 bic r0,r0,#4
 bic r0,r0,#4096
 mcr p15,0,r0,c1,c0,0
 isb
 movw sp,#0xfff0
 movt sp,#0x0002
 bl main
1: b 1b
''')
(O/'link.ld').write_text('ENTRY(_start)\nSECTIONS{. = 0x00008000;.text : {*(.text.start) *(.text*)}.rodata : {*(.rodata*)}.data : {*(.data*)}.bss : {*(.bss*)} ASSERT(. < 0x0002f000,"OCM loader overlaps stack") }\n')
(O/'manifest.json').write_text(json.dumps({'firmware_manifest':json.loads((FW.parent/'build_manifest.json').read_text()),'role':'TEST_GEOMETRY_ONLY_BOARD_SNAPSHOT','overlap':False,'audio_fifo_consumer':'Cortex-A9#0'},indent=2))
print('BOARD_PROFILE_SOURCE_PASS')
