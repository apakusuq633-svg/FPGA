param([string]$Tag='m5_impl')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if($Tag -notmatch '^[A-Za-z0-9_]+$'){throw 'Invalid tag'}
if(Get-Process vivado -ErrorAction SilentlyContinue){throw 'Another Vivado is running'}
$out=Join-Path $root ('build\zynq8_integrated_plan\'+$Tag)
$proj=Join-Path $root ('build\zynq8_integrated_plan\'+$Tag+'_project')
if((Test-Path -LiteralPath $out) -or (Test-Path -LiteralPath $proj)){throw 'Use a new tag; existing results are protected'}
New-Item -ItemType Directory -Path $out | Out-Null
$sources=[ordered]@{}
foreach($folder in @('rtl','constrs','configs')){
 Get-ChildItem -LiteralPath (Join-Path $root $folder) -File -Recurse | ForEach-Object {
  $sources[$_.FullName.Substring($root.Length+1).Replace('\','/')]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower()
 }
}
$sources | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $out 'source_manifest.json')
$env:ZYNQ_PROJ_DIR=$proj;$env:ZYNQ_OUTPUT_DIR=$out;$env:DAS_ACTIVE_CHANNELS='8'
$env:LOCALIZER_FLOORPLAN='1';$env:ZYNQ_RESUME_IMPL='0'
Push-Location $root
try{
 & 'D:\Vivado\Vivado\2020.2\bin\vivado.bat' -mode batch -notrace -source (Join-Path $root 'scripts\run_zynq_flow.tcl') -log (Join-Path $out 'implementation.log') -journal (Join-Path $out 'implementation.jou') *> (Join-Path $out 'console.log')
 if($LASTEXITCODE -ne 0){throw 'Vivado process failed'}
 if(-not (Select-String -LiteralPath (Join-Path $out 'implementation.log') -Pattern '^FLOW_PASS' -Quiet)){throw 'FLOW_PASS absent'}
 Write-Output ('INTEGRATED_IMPL_PASS '+$out)
}finally{Pop-Location}
