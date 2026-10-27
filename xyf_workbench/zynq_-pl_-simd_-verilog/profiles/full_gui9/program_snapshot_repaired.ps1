# Independent repaired bundle. Default: integrity check only; no hardware.
param([switch]$Program,[switch]$OpenPage)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$entry=Join-Path $project 'build\snapshot_repair_20261026\gui_spectra\program.ps1'
if(-not(Test-Path -LiteralPath $entry)){throw 'Repaired release is missing'}
$argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$entry)
if($Program){$argsList+='-Program'}
if($OpenPage){$argsList+='-OpenPage'}
& powershell @argsList
exit $LASTEXITCODE
