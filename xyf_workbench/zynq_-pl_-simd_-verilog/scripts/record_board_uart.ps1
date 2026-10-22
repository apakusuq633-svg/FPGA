# Capture the PS UART console without third-party Python packages.
param(
    [Parameter(Mandatory=$true)][string]$Port,
    [ValidateRange(1,3600)][int]$Seconds = 30,
    [string]$Output = 'build\board_uart.log'
)
$ErrorActionPreference = 'Stop'
$target = [IO.Path]::GetFullPath($Output)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
if (Test-Path -LiteralPath $target) { throw "Log already exists; choose another -Output: $target" }
$serial = New-Object System.IO.Ports.SerialPort $Port,115200,None,8,One
$serial.Handshake = 'None'
$serial.ReadTimeout = 200
$writer = $null
try {
    $serial.Open()
    $writer = New-Object IO.StreamWriter($target, $false, (New-Object Text.UTF8Encoding($false)))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "Recording $Port at 115200 8N1 for $Seconds seconds. Launch the app now."
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        $chunk = $serial.ReadExisting()
        if ($chunk) { $writer.Write($chunk); $writer.Flush(); Write-Host -NoNewline $chunk }
        Start-Sleep -Milliseconds 50
    }
} finally {
    if ($writer) { $writer.Dispose() }
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
}
Write-Host "Saved $target"
