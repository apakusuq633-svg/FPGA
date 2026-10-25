param([string]$Python='C:\Users\21914\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',[int]$Port=8769)
$ErrorActionPreference='Stop'
$data=Join-Path $env:LOCALAPPDATA 'AcousticHealth9'
New-Item -ItemType Directory -Force -Path $data | Out-Null
Write-Host "After startup, open http://127.0.0.1:$Port/ . Ctrl+C stops PC archival; PS keeps monitoring."
& $Python (Join-Path $PSScriptRoot 'health9_archive.py') --db (Join-Path $data 'health.sqlite3') --port $Port
exit $LASTEXITCODE
