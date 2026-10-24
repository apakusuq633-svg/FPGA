# Local build only: no deployment or changes to the shared Vitis workspace.
param(
    [string]$ToolDir = 'D:\Vivado\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin',
    [string]$BspDir = 'D:\Vitis\PS-PL\export\PS-PL\sw\PS-PL\standalone_domain',
    [string]$AppDir = 'D:\Vitis\ui_app\src',
    [switch]$Live,
    [switch]$MatchingPlWindow,
    [switch]$DynamicReplay,
    [switch]$Localization16,
    [switch]$FixedDas16,
    [ValidateSet(4,8,9,12,16)][int]$ActiveChannels = 8,
    [int]$ShaftMilliHz = 25000
)
$ErrorActionPreference = 'Stop'
if ($Live -and $ActiveChannels -notin @(8,9)) { throw 'Supported live builds: planar8 or circular9' }
if ($FixedDas16 -and ($Localization16 -or -not $Live -or $ActiveChannels -ne 16)) { throw 'FixedDas16 requires live sixteen-channel mode and cannot be combined with Localization16' }
if ($Live -and $ActiveChannels -eq 16 -and -not $FixedDas16) { $Localization16 = $true }
if ($Localization16 -and $ActiveChannels -eq 12) { throw 'Localization16 selects the legacy sixteen-microphone profile' }
if ($Live -and -not $MatchingPlWindow) { throw 'Live mode requires -MatchingPlWindow and a matching loaded bitstream' }
$project = Split-Path -Parent $PSScriptRoot
$gcc = Join-Path $ToolDir 'arm-none-eabi-gcc.exe'
$nm = Join-Path $ToolDir 'arm-none-eabi-nm.exe'
$size = Join-Path $ToolDir 'arm-none-eabi-size.exe'
$linker = Join-Path $AppDir 'lscript.ld'
$spec = Join-Path $AppDir 'Xilinx.spec'
if ($Live -and $ActiveChannels -eq 9) {
    $localApp = Join-Path $project 'build\circular9_ui_link'
    New-Item -ItemType Directory -Force -Path $localApp | Out-Null
    $linker = Join-Path $localApp 'lscript.ld'
    $spec = Join-Path $localApp 'Xilinx.spec'
    $ld = [IO.File]::ReadAllText((Join-Path $project 'sw\lscript_ddr.ld'))
    $ld = $ld.Replace('LENGTH = 0x1FF00000','LENGTH = 0x03F00000')
    $ld = $ld.Replace('   ps7_ram_0 :','   c9_dma_mem : ORIGIN = 0x08000000, LENGTH = 0x100000' + "`n" + '   ps7_ram_0 :')
    $ld = [regex]::Replace($ld,'(?m)^_end = \.;\r?\n}', '_end = .;' + "`n" + '.c9_dma (NOLOAD) : { KEEP(*(.c9_dma)) } > c9_dma_mem' + "`n" + '}')
    $ld = $ld.Replace('_STACK_SIZE = DEFINED(_STACK_SIZE) ? _STACK_SIZE : 0x2000;','_STACK_SIZE = 0x10000;')
    $ld = $ld.Replace('_HEAP_SIZE = DEFINED(_HEAP_SIZE) ? _HEAP_SIZE : 0x2000;','_HEAP_SIZE = 0x40000;')
    [IO.File]::WriteAllText($linker,$ld)
    [IO.File]::WriteAllText($spec,"*startfile:`ncrti%O%s crtbegin%O%s`n")
}
$lib = Join-Path $BspDir 'bsplib\lib'
foreach ($path in @($gcc,$nm,$size,$linker,$spec,(Join-Path $lib 'libxil.a'),(Join-Path $lib 'liblwip4.a'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing build dependency: $path" }
}
$mode = if ($Live) { 'live' } else { 'replay' }
if ($Live -and $ActiveChannels -eq 9) { $mode = 'circular9' }
if ($Live -and $ActiveChannels -eq 4) { $mode = 'live4' }
if ($Live -and $ActiveChannels -eq 16) { $mode = 'live16' }
if ($Live -and $ActiveChannels -eq 12) { $mode = 'live12' }
if ($Localization16) {
    if (-not $Live -or $ActiveChannels -ne 16) { throw 'Localization16 requires live sixteen-channel mode' }
    $mode = 'live16_loc'
}
$out = Join-Path $project "build\ui_pipeline_$mode"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$obj = Join-Path $out 'ui.o'
$elf = Join-Path $out 'ui.elf'
$defs = @("-DUI_SHAFT_MILLIHZ=$ShaftMilliHz")
$defs += "-DUI_DAS_ACTIVE_CHANNELS=$ActiveChannels"
if ($Localization16) { $defs += '-DUI_LIVE16_LOCALIZATION=1' }
if ($FixedDas16) { $defs += '-DUI_LIVE16_LOCALIZATION=0' }
if ($DynamicReplay) {
    if ($Live) { throw 'DynamicReplay is synthetic and cannot be combined with Live' }
    $defs += '-DUI_DYNAMIC_REPLAY=1'
}
if ($Live) { $defs += @('-DUI_DAS_LIVE=1','-DUI_DAS_WINDOW_PRESENT=1') }
if ($Live) {
    $imageHeader = if ($ActiveChannels -eq 9) { 'sw\acoustic_circular9_image.h' } elseif ($ActiveChannels -eq 8) { 'sw\acoustic_planar8_image.h' } elseif ($ActiveChannels -eq 12) { 'sw\acoustic_live12_image.h' } elseif ($Localization16) { 'sw\acoustic_live16_image.h' } elseif ($ActiveChannels -eq 16) { 'sw\acoustic_live16_fixed_image.h' } elseif ($ActiveChannels -eq 4) { 'sw\acoustic_debug4_image.h' } else { 'sw\acoustic_live_image.h' }
    $text = [IO.File]::ReadAllText((Join-Path $project $imageHeader))
    foreach ($memory in @('ITCM','DTCM')) {
        $expected = [regex]::Match($text, ('ACOUSTIC_' + $memory + '_SHA256 "([0-9a-f]{64})"'))
        $image = if ($ActiveChannels -eq 9) { Join-Path $project ('build\circular9\fw\' + $memory.ToLowerInvariant() + '.hex') } elseif ($ActiveChannels -eq 8) { Join-Path $project ('build\das8\fw\' + $memory.ToLowerInvariant() + '.hex') } elseif ($ActiveChannels -eq 12) { Join-Path $project ('build\das12\fw\' + $memory.ToLowerInvariant() + '.hex') } elseif ($Localization16) { Join-Path $project ('build\das16_loc\fw\' + $memory.ToLowerInvariant() + '.hex') } elseif ($ActiveChannels -eq 16) { Join-Path $project ('build\das16\fw\' + $memory.ToLowerInvariant() + '.hex') } elseif ($ActiveChannels -eq 4) { Join-Path $project ('build\das4\fw\' + $memory.ToLowerInvariant() + '.hex') } else { Join-Path $project ('sw\fw\fw_live_' + $memory.ToLowerInvariant() + '.hex') }
        if (-not $expected.Success -or (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.Groups[1].Value) { throw 'Live firmware image hash mismatch; regenerate images before building' }
    }
}
& $gcc -std=c11 -Wall -Wextra -Werror -O2 -g -fstack-usage -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard `
    "-I$(Join-Path $BspDir 'bspinclude\include')" "-I$(Join-Path $project 'sw')" @defs `
    -o $obj (Join-Path $project 'sw\ps_ui.c')
if ($LASTEXITCODE -ne 0) { throw 'UI ARM compile failed' }
$objects = @($obj)
if ($Live -and $ActiveChannels -eq 9) {
    foreach ($unit in @('gsc9','pdm_stream','circular9_stream','circular9_audio')) {
        $unitObj = Join-Path $out "$unit.o"
        & $gcc -std=c11 -Wall -Wextra -Werror -O2 -g -fstack-usage -c -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard `
            "-I$(Join-Path $BspDir 'bspinclude\include')" "-I$(Join-Path $project 'sw')" @defs `
            -o $unitObj (Join-Path $project "sw\$unit.c")
        if ($LASTEXITCODE -ne 0) { throw "UI ARM compile failed: $unit" }
        $objects += $unitObj
    }
}
& $gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard "-specs=$spec" '-Wl,-build-id=none' `
    "-Wl,-T,$linker" "-Wl,-Map,$(Join-Path $out 'ui.map')" "-L$lib" -o $elf @objects `
    '-Wl,--start-group' -llwip4 -lxil -lgcc -lc '-Wl,--end-group'
if ($LASTEXITCODE -ne 0) { throw 'UI ARM BSP link failed' }
$symbols = & $nm -S $elf
if ($LASTEXITCODE -ne 0) { throw 'UI symbol inspection failed' }
$entry = $symbols | Where-Object { $_ -match '\baudio_shared$' }
if ($entry -notmatch '^([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\w\s+audio_shared$') { throw 'Shared queue symbol missing' }
$audioAddress = [Convert]::ToUInt64($Matches[1],16)
$audioSize = [Convert]::ToUInt64($Matches[2],16)
if (($audioAddress % 1048576) -ne 0 -or $audioSize -ne 1048576) { throw 'Shared DDR section must be isolated and 1 MB aligned' }
if ($Live -and $ActiveChannels -eq 9) {
    $dmaSymbol = $symbols | Where-Object { $_ -match '\bc9_ddr$' }
    if ($dmaSymbol -notmatch '^([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\w\s+c9_ddr$') { throw 'DMA section missing' }
    $dmaAddress = [Convert]::ToUInt64($Matches[1],16)
    $dmaSize = [Convert]::ToUInt64($Matches[2],16)
    if (($dmaAddress % 1048576) -ne 0 -or $dmaSize -ne 1048576 -or $dmaAddress -lt 0x01000000 -or $dmaAddress + $dmaSize -gt 0x10000000) { throw 'DMA section outside supported aligned DDR range' }
}
& $size $elf
Write-Host "UI_PIPELINE_BUILD_PASS: $mode, shared DDR section at 0x$($audioAddress.ToString('x')), $elf"
