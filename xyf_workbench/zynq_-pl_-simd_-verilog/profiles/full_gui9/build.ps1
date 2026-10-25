# Reproducible local PS/GUI build using matched hardware; no JTAG access.
param([string]$Python='C:\Users\21914\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
 [string]$BspWorkspace='F:\RISC-V\pipeline_latest2\build\c9bsp_gui25',
 [string]$ToolDir='E:\Vivado2020.2\Vitis\2020.2\gnu\aarch32\nt\gcc-arm-none-eabi\bin')
$ErrorActionPreference='Stop'
$project=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
& $Python (Join-Path $PSScriptRoot 'make_ui.py')
if($LASTEXITCODE -ne 0){throw 'Page generation failed'}
& $Python (Join-Path $PSScriptRoot 'check.py')
if($LASTEXITCODE -ne 0){throw 'GUI checks failed'}
$bsp=Join-Path $BspWorkspace 'circular9\export\circular9\sw\circular9\standalone_domain'
& (Join-Path $project 'scripts\build_ui_pipeline.ps1') -Live -MatchingPlWindow -ActiveChannels 9 -ToolDir $ToolDir -BspDir $bsp
if($LASTEXITCODE -ne 0){throw 'PS build failed'}
& $Python (Join-Path $PSScriptRoot 'release.py') --workspace $BspWorkspace
if($LASTEXITCODE -ne 0){throw 'Release consistency checks failed'}
Write-Host 'FULL_GUI9_LOCAL_BUILD_PASS. No hardware accessed.'
