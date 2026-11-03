param([switch]$Program,[string]$Xsct='E:\Vivado2020.2\Vitis\2020.2\bin\xsct.bat')
$ErrorActionPreference='Stop'
$dir=$PSScriptRoot
if(-not(Test-Path (Join-Path $dir 'manifest.json'))){$dir=Join-Path (Split-Path -Parent (Split-Path -Parent $dir)) 'build\raw9_128k_release_txreclaim'}
$m=Get-Content (Join-Path $dir 'manifest.json') -Raw | ConvertFrom-Json
if($m.channels -ne 9 -or $m.sample_rate -ne 128000){throw 'Wrong recording profile'}
foreach($f in $m.files.PSObject.Properties){if((Get-FileHash -LiteralPath (Join-Path $dir $f.Name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $f.Value){throw "Hash mismatch $($f.Name)"}}
Write-Host 'RAW9_FILES_PASS; independent recording profile, no localization/diagnosis GUI.'
if(-not $Program){Write-Host 'No board access. Add -Program only when ready.';exit 0}
& $Xsct (Join-Path $dir 'program.tcl') $dir
if($LASTEXITCODE){throw 'Recording program load failed'}
