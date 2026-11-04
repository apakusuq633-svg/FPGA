# Nine-microphone full GUI. Default: local integrity check, no board access.
param([switch]$Program,[switch]$OpenPage,[string]$XsctPath=$(if($env:XSCT_PATH){$env:XSCT_PATH}else{'E:\Vivado2020.2\Vitis\2020.2\bin\xsct.bat'}))
$ErrorActionPreference='Stop'
$project=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bundle=Join-Path $project 'build\full_gui9_release'
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'manifest.json')){$bundle=$PSScriptRoot}
$manifest=Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
if($manifest.channels -ne 9 -or $manifest.pdm_clock_hz -ne 2500000 -or $manifest.pcm_sample_rate_hz -ne 156250){throw 'Unexpected nine-microphone release profile'}
foreach($entry in $manifest.files.PSObject.Properties){
 $path=Join-Path $bundle $entry.Name
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$actual=[BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($actual -ne $entry.Value.sha256){throw "Release hash mismatch: $path"}
}
Write-Host 'FULL_GUI9_FILES_PASS: matched nine-microphone bitstream, PS ELF and initialization.'
if(-not $Program){Write-Host 'No hardware accessed. Add -Program to load; add -OpenPage to show the GUI.';exit 0}
if(-not (Test-Path -LiteralPath $XsctPath)){throw "XSCT not found: $XsctPath"}
$env:PSModulePath="$env:WINDIR\System32\WindowsPowerShell\v1.0\Modules;"+$env:PSModulePath
$log=Join-Path $bundle ('program_'+(Get-Date -Format yyyyMMdd_HHmmss)+'.log')
& $XsctPath (Join-Path $bundle 'program.tcl') $bundle *> $log
if($LASTEXITCODE -ne 0 -or [IO.File]::ReadAllText($log) -notmatch 'FULL_GUI9_RUNNING'){Get-Content -LiteralPath $log -Tail 20;throw "Board load failed; log: $log"}
Write-Host "FULL_GUI9_RUNNING. Volatile JTAG load; UART115200. Log: $log"
if($OpenPage){Start-Sleep -Seconds 3;Start-Process 'http://192.168.2.10/'}
