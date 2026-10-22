# Routed checkpoint acceptance only; never sources analysis clocks into a build.
param(
  [Parameter(Mandatory=$true)][string]$Checkpoint,
  [Parameter(Mandatory=$true)][string]$Manifest,
  [Parameter(Mandatory=$true)][string]$Output,
  [string]$Config='configs/pdm_external_assumptions.json',
  [string]$Vivado='D:\Vivado\Vivado\2020.2\bin\vivado.bat'
)
$ErrorActionPreference='Stop'
function WslPath([string]$p) {
  $s=[IO.Path]::GetFullPath($p).Replace('\','/')
  if($s -notmatch '^([A-Za-z]):/(.*)$'){throw 'Expected Windows drive path'}
  return '/mnt/'+$Matches[1].ToLower()+'/'+$Matches[2]
}
try {
  $root=Split-Path -Parent $PSScriptRoot
  Set-Location $root
  $out=[IO.Path]::GetFullPath($Output)
  $ck=[IO.Path]::GetFullPath($Checkpoint)
  $helper=WslPath (Join-Path $root 'scripts/pdm_external_acceptance.py')
  & wsl -e python3 $helper prepare --output (WslPath $out) --checkpoint (WslPath $ck) --manifest (WslPath $Manifest) --config (WslPath $Config)
  if($LASTEXITCODE -ne 0){throw 'PDM acceptance preflight failed'}
  & $Vivado -mode batch -notrace -source scripts/check_pdm_external_sta.tcl -log (Join-Path $out 'vivado.log') -journal (Join-Path $out 'vivado.jou') -tclargs --accept $ck (Join-Path $out 'window') (Join-Path $out 'numeric_config.tcl') | Out-Null
  if($LASTEXITCODE -ne 0){throw 'PDM external timing failed'}
  if(-not(Select-String -LiteralPath (Join-Path $out 'vivado.log') -SimpleMatch 'PDM_EXTERNAL_ACCEPTANCE_PASS_CONDITIONAL' -Quiet)){throw 'Vivado acceptance marker missing'}
  & wsl -e python3 $helper verify --output (WslPath $out)
  if($LASTEXITCODE -ne 0){throw 'PDM acceptance postflight failed'}
  exit 0
} catch {Write-Output ('PDM_EXTERNAL_AUTOMATION_FAIL '+$_);exit 1}
