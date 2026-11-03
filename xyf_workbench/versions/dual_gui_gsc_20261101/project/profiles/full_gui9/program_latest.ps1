# Current tested local artifacts; -Program is required for any board access.
param([switch]$Program,[switch]$OpenPage)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$entry=Join-Path $project 'build\gui_fixed_layout_20261030\program.ps1'
$argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$entry)
if($Program){$argsList+='-Program'}
if($OpenPage){$argsList+='-OpenPage'}
Write-Host 'Selected: nine-mic complete GUI fixed numeric layout; display only; board pending.'
& powershell @argsList
exit $LASTEXITCODE
