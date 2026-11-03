# Fresh isolated full SoC implementation. No source replacement in the workspace.
param([Parameter(Mandatory=$true)][string]$Overlay,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Set-Location $root
$out=[IO.Path]::GetFullPath($Output)
$overlayPath=(Resolve-Path -LiteralPath $Overlay).Path
if(Test-Path -LiteralPath $out){throw 'Fresh output required'}
$batch=Get-CimInstance Win32_Process -Filter "name='vivado.exe'" | Where-Object {$_.CommandLine -notmatch 'gui_launcher_event'}
if($batch){throw 'Another Vivado batch is active'}
$manifest=[ordered]@{}
foreach($f in (Get-ChildItem rtl -Recurse -File | Where-Object {$_.Extension -in @('.v','.vh')})) {
  $path=$f.FullName
  if($f.Name -in @('rv32_srp_scan.v','rv32_overlap_localizer.v')){$path=Join-Path $overlayPath $f.Name}
  $relative=$path.Substring($root.Length+1).Replace('\','/')
  $manifest[$relative]=(Get-FileHash -LiteralPath $path).Hash.ToLower()
}
$oldOverlay=$env:PDM_RAM_EXPERIMENT_OVERLAY
try {
  $env:PDM_RAM_EXPERIMENT_OVERLAY=$overlayPath
  & D:\Vivado\Vivado\2020.2\bin\vivado.bat -mode batch -notrace -source scripts/implement_pdm_soc.tcl -log ($out+'.log') -journal ($out+'.jou') -tclargs $out | Out-Null
  if($LASTEXITCODE -ne 0){throw 'RAM candidate full SoC implementation failed'}
  if(-not(Select-String -LiteralPath ($out+'.log') -SimpleMatch 'PDM_SOC_IMPL_PASS_CONDITIONAL' -Quiet)){throw 'Implementation PASS marker missing'}
  foreach($name in $manifest.Keys){if((Get-FileHash -LiteralPath (Join-Path $root $name)).Hash.ToLower() -ne $manifest[$name]){throw "Source changed during implementation: $name"}}
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $out 'source_manifest.json')
  Write-Output 'PDM_RAM_FULL_SOC_IMPL_PASS candidate_only=1'
} finally {$env:PDM_RAM_EXPERIMENT_OVERLAY=$oldOverlay}
