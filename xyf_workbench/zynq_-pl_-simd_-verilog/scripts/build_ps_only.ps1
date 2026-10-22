# Build the PS-only baseline for Cortex-A9 locally, without overwriting Vitis.
#
# What this is: the PS-only half of README section 34 ("PS-only vs PS+PL"). It
# compiles THE SAME firmware source (sw/fw/fw_main.c plus every kernel it calls)
# for the A9, which then computes the whole chain itself and times it with the
# PMU cycle counter. All three switches are required; dropping any one of them
# yields a different experiment:
#   -DFW_ACCEL=0            all scalar; same setting as the PL baseline image
#   -DFW_MEM_RELOCATE       the whole DTCM map moves into .bss (no DTCM on the A9)
#   -DFW_RDCYCLE_OVERRIDE   cycle counter becomes PMU CCnt (the core uses csrr)
# Whether both sides really run the same job is checked bit-for-bit, on the host,
# by scripts/check_ps_only_results.py -- that check is a precondition, not a
# bonus: if the two diverge the "speedup" compares two different jobs.
#
# Output: build/ps_only_arm/ps_only.elf -- compile/link only, NOT run on a board.
# On the board (once one is attached):
#   xsct scripts/run_board.tcl -app rv32_app -elf build/ps_only_arm/ps_only.elf
# The UART at 115200 prints PS_ONLY_CYCLES / PS_ONLY_RES / PS_ONLY_EXTRA.
#
# Keep this file ASCII-only -- see the note at the top of scripts/verify.ps1.
param(
    [string]$ToolDir = 'D:\Vivado\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin',
    [string]$BspDir = 'D:\Vitis\PS-PL\export\PS-PL\sw\PS-PL\standalone_domain',
    [string]$Spec = 'D:\Vitis\rv32_app\src\Xilinx.spec'
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$gcc = Join-Path $ToolDir 'arm-none-eabi-gcc.exe'
$size = Join-Path $ToolDir 'arm-none-eabi-size.exe'
foreach ($path in @($gcc, $size, $Spec, (Join-Path $BspDir 'bsplib\lib\libxil.a'))) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required artifact missing: $path" }
}

$out = Join-Path $project 'build\ps_only_arm'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$defs = @('-DFW_ACCEL=0', '-DFW_MEM_RELOCATE', '-DFW_RDCYCLE_OVERRIDE')
$incs = @("-I$(Join-Path $BspDir 'bspinclude\include')",
          "-I$(Join-Path $project 'sw')",
          "-I$(Join-Path $project 'sw\fw')")
$cflags = @('-Wall', '-Wextra', '-O2', '-g', '-mcpu=cortex-a9', '-mfpu=vfpv3',
            '-mfloat-abi=hard') + $defs + $incs

# Unlike the PL build, fw_steer.c is NOT compiled here: the steering block is PL
# hardware and does not exist on the A9, so ps_only.c supplies a stub and section
# 9 is skipped. That is the only workload difference between the two sides --
# about 2.6% of the round, and it must be subtracted when reporting the ratio.
$sources = @('sw\ps_only.c', 'sw\fw\fw_fft.c', 'sw\fw\fw_gcc.c', 'sw\fw\fw_srp.c',
             'sw\fw\fw_das.c', 'sw\fw\fw_fir.c', 'sw\fw\fw_scene.c', 'sw\fw\fw_tables.c')
$objs = @()
foreach ($src in $sources) {
    $obj = Join-Path $out ([IO.Path]::GetFileNameWithoutExtension($src) + '.o')
    & $gcc @cflags -c -o $obj (Join-Path $project $src)
    if ($LASTEXITCODE -ne 0) { throw "ARM compile failed: $src" }
    $objs += $obj
}

$elf = Join-Path $out 'ps_only.elf'
& $gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard '-Wl,-build-id=none' `
    "-specs=$Spec" '-Wl,-T' "-Wl,$(Join-Path $project 'sw\lscript_ddr.ld')" `
    "-L$(Join-Path $BspDir 'bsplib\lib')" -o $elf @objs `
    '-Wl,--start-group' -lxil -lgcc -lc '-Wl,--end-group'
if ($LASTEXITCODE -ne 0) { throw 'PS-only ARM BSP link failed' }
& $size $elf
if ($LASTEXITCODE -ne 0) { throw 'ARM ELF inspection failed' }
Write-Host "PS_ONLY_ARM_BUILD_PASS: $elf (compile/link only; no board execution)"
