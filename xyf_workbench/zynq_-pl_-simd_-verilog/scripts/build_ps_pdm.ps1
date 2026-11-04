# Cortex-A9 compile/link verification only. Does not connect to hardware.
param([Parameter(Mandatory=$true)][string]$Bsp,[Parameter(Mandatory=$true)][string]$LinkerScript,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Set-Location $root
$out=[IO.Path]::GetFullPath($Output)
if(Test-Path -LiteralPath $out){throw 'Fresh output required'}
New-Item -ItemType Directory -Path $out | Out-Null
$bspPath=(Resolve-Path -LiteralPath $Bsp).Path
$ld=(Resolve-Path -LiteralPath $LinkerScript).Path
$tool=$(if($env:ARM_TOOL_DIR){$env:ARM_TOOL_DIR}else{'D:\Vivado\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin'})
$cc=Join-Path $tool 'arm-none-eabi-gcc.exe'
foreach($p in @($cc,"$bspPath/include/xil_io.h","$bspPath/lib/libxil.a")){if(-not(Test-Path -LiteralPath $p)){throw "Missing $p"}}
$spec=Join-Path $out 'Xilinx.spec'
[IO.File]::WriteAllText($spec,"*startfile:`ncrti%O%s crtbegin%O%s`n")
$compile=@('-std=c11','-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard','-O2','-Wall','-Wextra','-Werror',"-I$bspPath/include",'-c',"$root/sw/ps_pdm.c",'-o',"$out/ps_pdm.o")
$link=@('-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard',"-specs=$spec",'-Wl,--build-id=none',"-Wl,-T,$ld","-Wl,-Map,$out/ps_pdm.map","-L$bspPath/lib",'-o',"$out/ps_pdm.elf","$out/ps_pdm.o",'-Wl,--start-group','-lxil','-lgcc','-lc','-Wl,--end-group')
& $cc --version > "$out/version.txt"
& $cc @compile *> "$out/compile.log"
if($LASTEXITCODE -ne 0){throw 'ARM compile failed'}
& $cc @link *> "$out/link.log"
if($LASTEXITCODE -ne 0){throw 'ARM link failed'}
& "$tool/arm-none-eabi-size.exe" "$out/ps_pdm.elf" > "$out/size.txt"
[ordered]@{status='PASS_COMPILE_LINK_ONLY';hardware='UNVERIFIED_HARDWARE';compiler=$cc;compile=$compile;link=$link;source_sha256=(Get-FileHash -LiteralPath sw/ps_pdm.c).Hash.ToLower();bsp=$bspPath;libxil_sha256=(Get-FileHash -LiteralPath "$bspPath/lib/libxil.a").Hash.ToLower();linker_sha256=(Get-FileHash -LiteralPath $ld).Hash.ToLower();elf_sha256=(Get-FileHash -LiteralPath "$out/ps_pdm.elf").Hash.ToLower()} | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "$out/manifest.json"
Write-Output 'PS_PDM_ARM_COMPILE_LINK_PASS hardware=UNVERIFIED_HARDWARE'
