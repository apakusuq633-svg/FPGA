# Current tested local artifacts; -Program is required for any board access.
param([switch]$Program,[switch]$OpenPage)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$entry=Join-Path $project 'build\gui_heatmap_8khz_20261026\program.ps1'
$argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$entry)
if($Program){$argsList+='-Program'}
if($OpenPage){$argsList+='-OpenPage'}
Write-Host 'Selected: nine-mic GUI heatmap display + 0-8kHz spectrum (2026-10-26).'
& powershell @argsList
exit $LASTEXITCODE
