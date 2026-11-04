# Compile/link only. No connect, download, reset or network operations.
param(
 [Parameter(Mandatory=$true)][string]$PlatformDir,
 [Parameter(Mandatory=$true)][string]$Xsa,
 [Parameter(Mandatory=$true)][string]$Output,
 [string]$GscProfile='',
 [switch]$AllowTestProfile,
 [switch]$EnableGsc
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$platform=(Resolve-Path -LiteralPath $PlatformDir).Path
$xsaPath=(Resolve-Path -LiteralPath $Xsa).Path
$exported=Join-Path $platform 'hw/das_fir.xsa'
if((Get-FileHash -LiteralPath $exported).Hash -ne (Get-FileHash -LiteralPath $xsaPath).Hash){throw 'BSP platform does not match requested XSA'}
if($EnableGsc -and -not $GscProfile){throw 'Enabling GSC requires an explicitly validated matching profile'}
$bsp=Join-Path $platform 'sw/pdm9/standalone_domain'
$lib=Join-Path $bsp 'bsplib/lib'
$include=Join-Path $bsp 'bspinclude/include'
$tool=$(if($env:ARM_TOOL_DIR){$env:ARM_TOOL_DIR}else{'D:\Vivado\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin'})
$out=Join-Path $root $Output
if(Test-Path -LiteralPath $out){throw 'Use a new output directory'}
foreach($path in @("$lib/libxil.a","$lib/liblwip4.a","$include/xparameters.h")){if(-not(Test-Path -LiteralPath $path)){throw "Missing $path"}}
New-Item -ItemType Directory -Path $out | Out-Null
# The DMA region is NOLOAD, outside BSS/heap/stack, and never shared with the
# application allocator. Application DDR is capped below 64MiB.
$ld=[IO.File]::ReadAllText((Join-Path $root 'sw/lscript_ddr.ld'))
$ld=$ld.Replace('_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;', '_STACK_SIZE = 0x10000;')
$ld=$ld.Replace('_HEAP_SIZE = DEFINED(_HEAP_SIZE) ? _HEAP_SIZE : 0x2000;', '_HEAP_SIZE = 0x20000;')
$ld=$ld.Replace('LENGTH = 0x1FF00000','LENGTH = 0x03F00000').Replace('   ps7_ram_0 :','   dma_ring_mem : ORIGIN = 0x08000000, LENGTH = 0x80000' + "`n" + '   ps7_ram_0 :')
$ld=[regex]::Replace($ld,'(?m)^_end = \.;\r?\n}', '_end = .;'+"`n"+'.dma_ring (NOLOAD) : { __dma_ring_start = .; . += 0x80000; __dma_ring_end = .; } > dma_ring_mem'+"`n"+'}')
if($ld -notmatch '__dma_ring_start'){throw 'Linker generation failed'}
[IO.File]::WriteAllText((Join-Path $out 'stream.ld'),$ld)
[IO.File]::WriteAllText((Join-Path $out 'Xilinx.spec'),"*startfile:`ncrti%O%s crtbegin%O%s`n")
$defs=@()
if($GscProfile){
 $profile=(Resolve-Path -LiteralPath $GscProfile).Path
 $unixProfile=$profile.Replace('\','/').Replace('D:','/mnt/d').Replace('C:','/mnt/c')
 $unixOut=$out.Replace('\','/').Replace('D:','/mnt/d').Replace('C:','/mnt/c')
 $testArgs=@();if($AllowTestProfile){$testArgs+='--allow-test'}
 # WSL emits an unrelated localhost proxy warning on stderr on this host.
 # Judge the generator by its exit status, while preserving all diagnostic text.
 $savedAction=$ErrorActionPreference
 try{$ErrorActionPreference='Continue'; & wsl python3 (Join-Path $root 'scripts/generate_ps_gsc_profile.py').Replace('\','/').Replace('D:','/mnt/d') --config $unixProfile --fir ($root.Replace('\','/').Replace('D:','/mnt/d')+'/build/fw_fir_coeff.hex') --output "$unixOut/pdm_profile.h" @testArgs *> "$out/profile.log"; $profileExit=$LASTEXITCODE}finally{$ErrorActionPreference=$savedAction}
 if($profileExit -ne 0){throw 'Profile validation failed'}
 $defs+='-DPDM_GSC_PROFILE=1'
}
if($EnableGsc){$defs+='-DPDM_ENABLE_GSC=1'}
$objects=@();$hashes=[ordered]@{}
foreach($name in @('ps_stream_udp','pdm_stream','gsc12','pdm12_calibration')){
 $source=Join-Path $root "sw/$name.c";$obj=Join-Path $out "$name.o"
 $hashes["sw/$name.c"]=(Get-FileHash -LiteralPath $source).Hash.ToLower()
 & "$tool/arm-none-eabi-gcc.exe" -std=c11 -Wall -Wextra -Werror -O2 -g -fstack-usage -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard "-I$include" "-I$root/sw" "-I$out" @defs $source -o $obj *> "$out/$name.compile.log"
 if($LASTEXITCODE -ne 0){throw "ARM compile failed: $name"};$objects+=$obj
}
$elf=Join-Path $out 'pdm_stream.elf'
& "$tool/arm-none-eabi-gcc.exe" -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard "-specs=$out/Xilinx.spec" '-Wl,--build-id=none' "-Wl,-T,$out/stream.ld" "-Wl,-Map,$out/stream.map" "-L$lib" -o $elf @objects '-Wl,--start-group' -llwip4 -lxil -lgcc -lc '-Wl,--end-group' *> "$out/link.log"
if($LASTEXITCODE -ne 0){throw 'ARM link failed'}
$symbols=& "$tool/arm-none-eabi-nm.exe" -n $elf
$symbols | Set-Content -Encoding UTF8 "$out/symbols.txt"
foreach($pair in @(@('__dma_ring_start','08000000'),@('__dma_ring_end','08080000'))){if(-not($symbols -match ('^'+$pair[1]+'\s+\w\s+'+$pair[0]+'$'))){throw 'DMA linker reservation incorrect'}}
function Get-SymbolAddress([string]$Name){
 $line=@($symbols | Where-Object {$_ -match ('^[0-9a-fA-F]+\s+\w\s+'+[regex]::Escape($Name)+'$')})
 if($line.Count -ne 1){throw "Missing/duplicate symbol $Name"}
 return [Convert]::ToUInt64($line[0].Split(' ')[0],16)
}
if((Get-SymbolAddress '_heap_end')-(Get-SymbolAddress '_heap_start') -ne 0x20000){throw 'Heap reservation incorrect'}
if((Get-SymbolAddress '_stack')-(Get-SymbolAddress '_stack_end') -ne 0x10000){throw 'Stack reservation incorrect'}
if((Get-SymbolAddress '_end') -ge 0x04000000){throw 'Application overlaps reserved DDR'}
& "$tool/arm-none-eabi-size.exe" $elf | Set-Content -Encoding UTF8 "$out/size.txt"
$hashes['XSA']=(Get-FileHash -LiteralPath $xsaPath).Hash.ToLower()
foreach($f in @('libxil.a','liblwip4.a')){$hashes[$f]=(Get-FileHash -LiteralPath "$lib/$f").Hash.ToLower()}
$hashes['ELF']=(Get-FileHash -LiteralPath $elf).Hash.ToLower()
@{status='PASS_BUILD_ONLY';hardware='NOT_EXECUTED';gsc_enabled=[bool]$EnableGsc;test_profile=[bool]$AllowTestProfile;source_hashes=$hashes;dma_base='0x08000000';dma_bytes=524288;board_actions='NONE'} | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "$out/build_manifest.json"
Write-Output "PS_STREAM_BUILD_PASS $elf hardware_execution=NOT_RUN"
