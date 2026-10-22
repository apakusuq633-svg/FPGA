param([int]$Seconds = 24)
$ErrorActionPreference = 'Stop'
function PeakBin($values) {
    $peak = 0
    for ($i=1; $i -lt $values.Count; $i++) { if ($values[$i] -gt $values[$peak]) { $peak=$i } }
    return $peak
}
$rows=@(); $watch=[Diagnostics.Stopwatch]::StartNew()
while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $raw=& curl.exe --fail --max-time 3 -sS http://192.168.2.10/api/status
    if ($LASTEXITCODE -ne 0) { throw 'HTTP failed' }
    $s=$raw | ConvertFrom-Json
    if ($s.have) {
        $stage=[int]([math]::Floor([double]$s.first_sample/160000)%2)
        $env=PeakBin $s.envelope; $audio=PeakBin $s.spectrum
        $expectedEnv=if ($stage -eq 0) {21} else {42}
        $expectedAudio=if ($stage -eq 0) {13} else {26}
        if ([math]::Abs($env-$expectedEnv) -gt 1 -or $audio -ne $expectedAudio) { throw "Unexpected peaks: stage=$stage env=$env audio=$audio" }
        if ($s.input_error -ne 0 -or $s.ps_dropped -ne 0 -or $s.pl_dropped -ne 0) { throw 'Input error or sample drops' }
        $rows += [pscustomobject]@{frame=$s.frame;first_sample=$s.first_sample;stage=$stage;
            envelope_peak_bin=$env;audio_peak_group=$audio;diag_ms=$s.diag_ms;status=$s}
    }
    Start-Sleep -Milliseconds 700
}
$rows | ConvertTo-Json -Depth 8 | Set-Content build/ui_board_dynamic.json -Encoding UTF8
$stages=@($rows.stage | Select-Object -Unique)
if ($stages.Count -ne 2) { throw 'Both stages were not observed' }
$rows | Select-Object frame,first_sample,stage,envelope_peak_bin,audio_peak_group,diag_ms | Format-Table
Write-Host 'DYNAMIC_BOARD_PASS: both audio/envelope peaks follow input switches; no drops'
