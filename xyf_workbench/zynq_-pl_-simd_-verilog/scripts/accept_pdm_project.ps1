# One reproducible software/conditional-STA gate. No hardware operations.
param(
 [Parameter(Mandatory=$true)][string]$Checkpoint,
 [Parameter(Mandatory=$true)][string]$Manifest,
 [Parameter(Mandatory=$true)][string]$Output,
 [string]$ExternalEvidence='',
 [string]$Config='configs/pdm_external_assumptions.json',
 [string]$Bsp='',
 [string]$LinkerScript=''
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Set-Location $root
function UnixPath([string]$p){$s=[IO.Path]::GetFullPath($p).Replace('\','/');if($s -notmatch '^([A-Za-z]):/(.*)$'){throw 'Drive path required'};return '/mnt/'+$Matches[1].ToLower()+'/'+$Matches[2]}
function RunPython([string[]]$arguments,[string]$log){
 $saved=$ErrorActionPreference
 try{$ErrorActionPreference='Continue'; & wsl -e python3 @arguments *> $log;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$saved}
 if($code -ne 0){throw "Python gate failed; see $log"}
}
try {
 $out=[IO.Path]::GetFullPath($Output)
 if(Test-Path -LiteralPath $out){throw 'Fresh output required'}
 New-Item -ItemType Directory -Path $out | Out-Null
 if($ExternalEvidence){
  $external=[IO.Path]::GetFullPath($ExternalEvidence)
  RunPython @((UnixPath scripts/pdm_external_acceptance.py),'verify','--output',(UnixPath $external)) "$out/external_verify.log"
  $e=Get-Content -Raw -LiteralPath "$external/inputs.json" | ConvertFrom-Json
  if($e.checkpoint_sha256 -ne (Get-FileHash -LiteralPath $Checkpoint).Hash.ToLower() -or $e.manifest_sha256 -ne (Get-FileHash -LiteralPath $Manifest).Hash.ToLower()){throw 'External evidence does not match requested checkpoint/manifest'}
 } else {
  $external=Join-Path $out 'external'
  & powershell -NoProfile -ExecutionPolicy Bypass -File scripts/accept_pdm_external.ps1 -Checkpoint $Checkpoint -Manifest $Manifest -Output $external -Config $Config *> "$out/external_gate.log"
  if($LASTEXITCODE -ne 0){throw 'External STA gate failed'}
 }
 RunPython @((UnixPath scripts/check_ps_pdm_startup.py),'--protocol','--output',(UnixPath "$out/ps")) "$out/ps.log"
 if($Bsp -or $LinkerScript){
  if(-not($Bsp -and $LinkerScript)){throw 'Both BSP and linker script are required'}
  & powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_ps_pdm.ps1 -Bsp $Bsp -LinkerScript $LinkerScript -Output "$out/arm" *> "$out/arm.log"
  if($LASTEXITCODE -ne 0){throw 'ARM compile/link gate failed'}
 }
 RunPython @((UnixPath scripts/accept_pdm_project.py),'--external',(UnixPath $external),'--ps',(UnixPath "$out/ps"),'--output',(UnixPath "$out/acceptance.json")) "$out/acceptance.log"
 Write-Output 'PDM_PROJECT_GATE_PASS_CONDITIONAL hardware=UNVERIFIED_HARDWARE'
 exit 0
} catch {Write-Output ('PDM_PROJECT_GATE_FAIL '+$_);exit 1}
