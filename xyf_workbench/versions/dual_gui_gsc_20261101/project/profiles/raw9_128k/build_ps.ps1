param([string]$BspDir='F:\RISC-V\pipeline_latest4\zynq_-pl_-simd_-verilog\build\raw9_128k_bsp\circular9\export\circular9\sw\circular9\standalone_domain')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$out=Join-Path $root 'build\raw9_128k_ps'
New-Item -ItemType Directory -Force $out | Out-Null
$gcc='E:\Vivado2020.2\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe'
$inc=Join-Path $BspDir 'bspinclude\include';$lib=Join-Path $BspDir 'bsplib\lib'
$spec=Join-Path $out 'Xilinx.spec';[IO.File]::WriteAllText($spec,"*startfile:`ncrti%O%s crtbegin%O%s`n")
$ld=[IO.File]::ReadAllText((Join-Path $root 'sw/lscript_ddr.ld'))
$ld=$ld.Replace('LENGTH = 0x1FF00000','LENGTH = 0x03F00000').Replace('   ps7_ram_0 :',"   raw_dma_mem : ORIGIN = 0x08000000, LENGTH = 0x100000`n   ps7_ram_0 :")
$ld=[regex]::Replace($ld,'(?m)^_end = \.;\r?\n}',"_end = .;`n.c9_dma (NOLOAD) : { KEEP(*(.c9_dma)) } > raw_dma_mem`n}")
$linker=Join-Path $out 'raw9.ld';[IO.File]::WriteAllText($linker,$ld)
$units=@('profiles/raw9_128k/sw/ps_raw9.c','profiles/raw9_128k/sw/raw9_record.c','sw/pdm_stream.c');$objs=@()
foreach($unit in $units){$obj=Join-Path $out (([IO.Path]::GetFileNameWithoutExtension($unit))+'.o');$objs+=$obj
 & $gcc -std=c11 -Wall -Wextra -Werror -O2 -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard "-I$inc" "-I$root\sw" "-I$PSScriptRoot\sw" -c (Join-Path $root $unit) -o $obj
 if($LASTEXITCODE){throw "Compile failed $unit"}}
& $gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard "-specs=$spec" "-Wl,-T,$linker" "-Wl,-Map,$out\raw9.map" "-L$lib" -o "$out\raw9.elf" @objs '-Wl,--start-group' -llwip4 -lxil -lgcc -lc '-Wl,--end-group'
if($LASTEXITCODE){throw 'Link failed'}
Get-FileHash "$out\raw9.elf" -Algorithm SHA256
