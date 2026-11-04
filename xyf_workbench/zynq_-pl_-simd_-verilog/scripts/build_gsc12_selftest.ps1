param([string]$Tag='m8_20261016_selftest')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root ('build\'+$Tag)
if(Test-Path -LiteralPath $out){throw 'Use a new output directory'}
New-Item -ItemType Directory -Path $out | Out-Null
$inputDir=Join-Path $root 'build\m8_20261016\rtl_packets'
$rows=@(Get-Content -LiteralPath (Join-Path $inputDir 'packets.hex'))
if($rows.Count -ne 256){throw 'Expected 256 real RTL packets'}
$packetRows=foreach($row in $rows){
 $words=for($i=0;$i -lt 16;$i++){'0x'+$row.Substring(120-8*$i,8)+'u'}
 '{'+($words -join ',')+'}'
}
$expectedBytes=[IO.File]::ReadAllBytes((Join-Path $inputDir 'gsc_output.bin'))
$expected=for($i=0;$i -lt 256;$i++){[BitConverter]::ToInt16($expectedBytes,2*$i)}
$delays=(Get-Content -LiteralPath (Join-Path $inputDir 'delay.hex') | ForEach-Object {'0x'+$_+'u'}) -join ','
$coeff=(Get-Content -LiteralPath (Join-Path $inputDir 'fir.hex') | ForEach-Object {$v=[Convert]::ToInt32($_,16);if($v -ge 32768){$v-=65536};$v}) -join ','
$program=@"
#include "gsc12.h"
static const uint32_t packets[256][16]={
$($packetRows -join ",`n")
};
static const int16_t expected[256]={$($expected -join ',')};
static const gsc12_config config={1,0,7,8192,1048576,{$delays},{$coeff}};
static gsc12_state state;
volatile uint32_t gsc12_selftest_status=0;
volatile uint32_t gsc12_selftest_first_bad=0xffffffffu;
void *memset(void *p,int v,size_t n){volatile uint8_t *d=p;for(size_t i=0;i<n;i++)d[i]=(uint8_t)v;return p;}
void *memcpy(void *p,const void *s,size_t n){volatile uint8_t *d=p;const volatile uint8_t *v=s;for(size_t i=0;i<n;i++)d[i]=v[i];return p;}
void gsc12_selftest_main(void){
 gsc12_selftest_status=0x52554e31u;gsc12_reset(&state);
 if(gsc12_configure(&state,&config)){gsc12_selftest_status=0x43464745u;return;}
 for(unsigned i=0;i<256;i++)if(gsc12_process(&state,packets[i],1,0)!=expected[i]){
   gsc12_selftest_first_bad=i;gsc12_selftest_status=0x4641494cu;return;
 }
 gsc12_selftest_status=0x50415353u;
}
"@
[IO.File]::WriteAllText((Join-Path $out 'selftest.c'),$program)
$start=@'
.syntax unified
.arm
.section .text.startup,"ax"
.global _start
_start:
 cpsid if
 ldr sp,=0x03f00000
 bl gsc12_selftest_main
1: b 1b
'@
[IO.File]::WriteAllText((Join-Path $out 'start.S'),$start)
$linker=@'
ENTRY(_start)
SECTIONS {
 . = 0x00100000;
 .text : { KEEP(*(.text.startup)) *(.text*) }
 .rodata : { *(.rodata*) }
 .data : { *(.data*) }
 .bss (NOLOAD) : { *(.bss*) *(COMMON) }
 .ARM.exidx : { *(.ARM.exidx*) }
}
'@
[IO.File]::WriteAllText((Join-Path $out 'selftest.ld'),$linker)
$tool=$(if($env:ARM_TOOL_DIR){$env:ARM_TOOL_DIR}else{'D:\Vivado\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin'})
& "$tool\arm-none-eabi-gcc.exe" -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -O2 -ffreestanding -fno-builtin -fno-stack-protector -nostdlib -Wall -Wextra -Werror -I (Join-Path $root 'sw') (Join-Path $root 'sw\gsc12.c') (Join-Path $out 'selftest.c') (Join-Path $out 'start.S') "-Wl,-T,$out\selftest.ld" '-Wl,--build-id=none' -lgcc -o (Join-Path $out 'gsc12_selftest.elf') *> (Join-Path $out 'compile.log')
if($LASTEXITCODE -ne 0){throw 'ARM ELF link failed'}
& "$tool\arm-none-eabi-size.exe" (Join-Path $out 'gsc12_selftest.elf') | Set-Content -Encoding UTF8 (Join-Path $out 'size.txt')
& "$tool\arm-none-eabi-nm.exe" -n (Join-Path $out 'gsc12_selftest.elf') | Set-Content -Encoding UTF8 (Join-Path $out 'symbols.txt')
Write-Output ('GSC12_ARM_SELFTEST_BUILD_PASS '+$out+' hardware_execution=NOT_RUN')
