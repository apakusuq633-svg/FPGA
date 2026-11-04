# Reproducible local PS/GUI build using matched hardware; no JTAG access.
param([string]$Python=$env:C9_PYTHON,
 [string]$BspWorkspace=$env:C9_BSP_WORKSPACE,
 [string]$ToolDir=$env:C9_TOOL_DIR)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($Python)){
  $cmd=Get-Command python -ErrorAction SilentlyContinue
  if($cmd){$Python=$cmd.Source}else{throw 'Python not found: install Python 3 or pass -Python <path>'}
}
if([string]::IsNullOrWhiteSpace($BspWorkspace)){throw 'BspWorkspace not set: pass -BspWorkspace <Vitis BSP workspace> or set C9_BSP_WORKSPACE'}
if([string]::IsNullOrWhiteSpace($ToolDir)){throw 'ToolDir not set: pass -ToolDir <arm-none-eabi bin> or set C9_TOOL_DIR'}
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
