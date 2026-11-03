param([ValidateRange(10,300)][int]$Seconds=30,
      [string]$Address='http://192.168.2.10',
      [string]$Output='build/das4/live_board_monitor.json')
$ErrorActionPreference='Stop'
$samples=@()
$watch=[Diagnostics.Stopwatch]::StartNew()
while($watch.Elapsed.TotalSeconds -lt $Seconds) {
    $raw=& curl.exe --fail --max-time 3 -sS "$Address/api/status"
    if($LASTEXITCODE -ne 0) { throw 'Board HTTP request failed' }
    $status=$raw | ConvertFrom-Json
    if($status.input_mode -ne 2 -or $status.input_channels -ne 4 -or $status.input_error -ne 0) {
        throw "Wrong source/channel count or input failure: $raw"
    }
    if($status.have) {
        if($status.display_dsp -ne 1 -or $status.mic_valid -ne 1 -or $status.mic_rms_ppm.Count -ne 4 -or
           $status.rms_ppm -eq $null -or $status.envelope[0] -ne 0) { throw 'Missing corrected DSP or microphone level data' }
        if($status.synthetic -ne 0 -or $status.sample_count -ne 40000 -or
           $status.envelope.Count -ne 128 -or $status.spectrum.Count -ne 128) {
            throw 'Unexpected audio result or missing plots'
        }
    }
    $samples += [pscustomobject]@{elapsed_s=$watch.Elapsed.TotalSeconds;status=$status}
    Start-Sleep -Milliseconds 500
}
$samples | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Output -Encoding UTF8
$ready=@($samples | Where-Object {$_.status.have})
if($ready.Count -lt 2) { throw 'No completed real audio segments' }
$first=$ready[0].status
$last=$ready[-1].status
if($last.frame -le $first.frame -or $last.received_blocks -le $first.received_blocks -or $last.mic_seq -le $first.mic_seq -or
   $last.pl_dropped -ne 0 -or $last.ps_dropped -ne 0 -or $last.discontinuities -ne 0) {
    throw 'Audio stopped or drops/discontinuities occurred; inspect saved monitor log'
}
$plots=@($ready | ForEach-Object { ($_.status.spectrum -join ',')+';'+($_.status.envelope -join ',') } | Select-Object -Unique)
[pscustomobject]@{
    requests=$samples.Count; frames=$last.frame-$first.frame;
    blocks=$last.received_blocks-$first.received_blocks;
    diagnostic_ms_max=($ready.status.diag_ms | Measure-Object -Maximum).Maximum;
    distinct_plots=$plots.Count; pl_dropped=$last.pl_dropped; ps_dropped=$last.ps_dropped;
    mic_seq_delta=$last.mic_seq-$first.mic_seq; rms_ppm=$last.rms_ppm; dc_ppm=$last.spectrum_dc_ppm;
    output=$Output; localization_checked=$false
} | Format-List
Write-Host 'LIVE4_TRANSPORT_PASS: real source, blocks, segments, DSP results and HTTP; microphone wiring/response still requires stimulus check.'
