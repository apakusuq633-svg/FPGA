param([int]$Seconds = 45, [string]$Address = 'http://192.168.2.10', [string]$Output = 'build/ui_board_monitor.json')
$ErrorActionPreference = 'Stop'
$samples = @()
$watch = [Diagnostics.Stopwatch]::StartNew()
while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $raw = & curl.exe --fail --max-time 3 -sS "$Address/api/status"
    if ($LASTEXITCODE -ne 0) { throw 'Board HTTP request failed' }
    $status = $raw | ConvertFrom-Json
    if ($status.input_mode -ne 1 -or $status.input_error -ne 0 -or $status.sample_count -ne 40000) { throw 'Unexpected replay status' }
    if ($status.envelope.Count -ne 128 -or $status.spectrum.Count -ne 128) { throw 'Missing plot data' }
    $samples += [pscustomobject]@{elapsed_s=$watch.Elapsed.TotalSeconds; status=$status}
    Start-Sleep -Milliseconds 1000
}
$samples | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Output -Encoding UTF8
$first = $samples[0].status
$last = $samples[-1].status
$delta = [uint64]$last.first_sample - [uint64]$first.first_sample
$elapsed = $samples[-1].elapsed_s - $samples[0].elapsed_s
[pscustomobject]@{requests=$samples.Count; elapsed_s=[math]::Round($elapsed,3); frames=$last.frame-$first.frame;
    diagnostic_ms_min=($samples.status.diag_ms | Measure-Object -Minimum).Minimum;
    diagnostic_ms_max=($samples.status.diag_ms | Measure-Object -Maximum).Maximum;
    pl_drop_delta=$last.pl_dropped-$first.pl_dropped; ps_drop_delta=$last.ps_dropped-$first.ps_dropped;
    reset_delta=$last.discontinuities-$first.discontinuities; latest_age_ms=$last.age_ms;
    audio_timeline_rate_hz=[math]::Round($delta/$elapsed,2); output=$Output} | Format-List
if ($last.frame -le $first.frame -or $last.ps_dropped -ne $first.ps_dropped -or $last.pl_dropped -ne $first.pl_dropped) { throw 'No progress or drops grew during monitoring' }
