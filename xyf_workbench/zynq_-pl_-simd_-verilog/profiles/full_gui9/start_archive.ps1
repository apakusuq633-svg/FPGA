param([string]$Python=$env:C9_PYTHON,[int]$Port=8769)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($Python)){
  $cmd=Get-Command python -ErrorAction SilentlyContinue
  if($cmd){$Python=$cmd.Source}else{throw 'Python not found: install Python 3 or pass -Python <path>'}
}
$data=Join-Path $env:LOCALAPPDATA 'AcousticHealth9'
New-Item -ItemType Directory -Force -Path $data | Out-Null
Write-Host "After startup, open http://127.0.0.1:$Port/ . Ctrl+C stops PC archival; PS keeps monitoring."
& $Python (Join-Path $PSScriptRoot 'health9_archive.py') --db (Join-Path $data 'health.sqlite3') --port $Port
exit $LASTEXITCODE
