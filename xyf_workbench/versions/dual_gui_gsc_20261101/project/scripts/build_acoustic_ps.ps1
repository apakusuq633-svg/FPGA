# Build the acoustic Cortex-A9 application locally, without overwriting Vitis.
param(
    [switch]$Live,
    [ValidateSet(8,9)][int]$ActiveChannels = 8,
    [string]$ToolDir = 'D:\Vivado\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin',
    [string]$BspDir = 'D:\Vitis\PS-PL\export\PS-PL\sw\PS-PL\standalone_domain',
    [string]$Spec = 'D:\Vitis\rv32_app\src\Xilinx.spec'
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$header = Join-Path $project $(if ($Live -and $ActiveChannels -eq 9) { 'sw\acoustic_circular9_image.h' } elseif ($Live) { 'sw\acoustic_planar8_image.h' } else { 'sw\acoustic_image.h' })
$image = Join-Path $project $(if ($Live -and $ActiveChannels -eq 9) { 'build\circular9\fw\itcm.hex' } elseif ($Live) { 'build\das8\fw\itcm.hex' } else { 'sw\fw\fw_itcm.hex' })
$dataImage = Join-Path $project $(if ($Live -and $ActiveChannels -eq 9) { 'build\circular9\fw\dtcm.hex' } elseif ($Live) { 'build\das8\fw\dtcm.hex' } else { 'sw\fw\fw_dtcm.hex' })
$gcc = Join-Path $ToolDir 'arm-none-eabi-gcc.exe'
$size = Join-Path $ToolDir 'arm-none-eabi-size.exe'
foreach ($path in @($gcc, $size, $Spec, $header, (Join-Path $BspDir 'bsplib\lib\libxil.a'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required artifact missing: $path" }
}
foreach ($pair in @(@('ITCM', $image), @('DTCM', $dataImage))) {
    $sha = [regex]::Match([IO.File]::ReadAllText($header), ('ACOUSTIC_' + $pair[0] + '_SHA256 "([0-9a-f]{64})"'))
    if (-not $sha.Success -or (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha.Groups[1].Value) {
        throw 'Stale acoustic image header: regenerate the matching firmware first (scripts/build_planar8.py for live)'
    }
}
$out = Join-Path $project $(if ($ActiveChannels -eq 9) { 'build\circular9\ps' } else { 'build\acoustic_arm' })
New-Item -ItemType Directory -Force -Path $out | Out-Null
$obj = Join-Path $out $(if ($Live) { "planar$ActiveChannels.o" } else { 'acoustic.o' })
$elf = Join-Path $out $(if ($Live) { "live_das$ActiveChannels.elf" } else { 'acoustic_ddr.elf' })
& $gcc "-DLIVE_ACTIVE_CHANNELS=$ActiveChannels" -Wall -Wextra -Werror -O2 -g -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard `
    "-I$(Join-Path $BspDir 'bspinclude\include')" "-I$(Join-Path $project 'sw')" `
    -o $obj (Join-Path $project $(if ($Live) { 'sw\ps_live.c' } else { 'sw\ps_main.c' }))
if ($LASTEXITCODE -ne 0) { throw 'Acoustic ARM compile failed' }
& $gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard '-Wl,-build-id=none' `
    "-specs=$Spec" '-Wl,-T' "-Wl,$(Join-Path $project 'sw\lscript_ddr.ld')" `
    "-L$(Join-Path $BspDir 'bsplib\lib')" -o $elf $obj `
    '-Wl,--start-group' -lxil -lgcc -lc '-Wl,--end-group'
if ($LASTEXITCODE -ne 0) { throw 'Acoustic ARM BSP link failed' }
& $size $elf
if ($LASTEXITCODE -ne 0) { throw 'ARM ELF inspection failed' }
Write-Host "ACOUSTIC_ARM_BUILD_PASS: $elf (compile/link only; no board execution)"
