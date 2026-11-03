$ErrorActionPreference='Stop'
$probeDirectory=$PSScriptRoot
$workspace=Split-Path -Parent (Split-Path -Parent $probeDirectory)
$devices=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {$_.Class -eq 'Ports' -or $_.FriendlyName -match 'FTDI|JTAG|Xilinx|Digilent|Zynq|CP210|USB.Serial|USB Serial|UART'} | Select-Object Class,FriendlyName,InstanceId,Status)
$ports=@(Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue | Select-Object DeviceID,Name,Status)
$services=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {$_.Name -match 'hw_server|cs_server|vivado|xsct|openocd|jtag'} | Select-Object Name,ProcessId,ExecutablePath,CommandLine)
$state=[ordered]@{ObservedUTC=[DateTime]::UtcNow.ToString('o');PnPDevices=$devices;SerialPorts=$ports;ExistingHardwareProcesses=$services;ProbePort=3124;NoReset=$true;NoProgramming=$true;NoOpenTarget=$true}
$state|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $probeDirectory 'host_before.json') -Encoding UTF8
if(Get-NetTCPConnection -LocalPort 3124 -State Listen -ErrorAction SilentlyContinue){throw 'Probe port3124 already owned; no service changed'}
$serverExecutable='D:\AMDDesignTools\2025.2\Vivado\bin\unwrapped\win64.o\hw_server.exe'
$vivado='D:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat'
$serverProcess=$null
try {
 $serverProcess=Start-Process -FilePath $serverExecutable -ArgumentList @('-s','tcp::3124') -WorkingDirectory $probeDirectory -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $probeDirectory 'hw_server_stdout.log') -RedirectStandardError (Join-Path $probeDirectory 'hw_server_stderr.log')
 [pscustomobject]@{ProcessId=$serverProcess.Id;Executable=$serverExecutable;StartedUTC=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $probeDirectory 'owned_server.json') -Encoding UTF8
 $ready=$false
 for($i=0;$i-lt20;$i++){
  if(Get-NetTCPConnection -LocalPort 3124 -State Listen -ErrorAction SilentlyContinue){$ready=$true;break}
  $serverProcess.Refresh()
  if($serverProcess.HasExited){throw 'Owned read-only hardware server exited before listening'}
  Start-Sleep -Milliseconds 250
 }
 if(-not$ready){throw 'Read-only hardware server did not start on private port3124'}
 Push-Location -LiteralPath $probeDirectory
 try {
  & $vivado -mode batch -notrace -nolog -nojournal -source (Join-Path $probeDirectory 'enumerate_only.tcl') *> (Join-Path $probeDirectory 'vivado_enumeration.log')
  $code=$LASTEXITCODE
 } finally {Pop-Location}
 $log=Get-Content -LiteralPath (Join-Path $probeDirectory 'vivado_enumeration.log') -Raw
 $match=[regex]::Match($log,'TIMING_PROBE_TARGET_COUNT (\d+)')
 $count=if($match.Success){[int]$match.Groups[1].Value}else{$null}
 $state.VivadoExitCode=$code;$state.EnumeratedTargetCount=$count
 $state.TargetNames=@([regex]::Matches($log,'(?m)^TIMING_PROBE_TARGET (.+)$')|ForEach-Object{$_.Groups[1].Value.Trim()})
 $state.ReadOnlyMarker=($log-match'TIMING_PROBE_READ_ONLY_DONE no_open_target=1 no_programming=1 no_reset=1')
 if($code-ne0-or-not$match.Success){$state.Error='Enumeration did not complete normally; inspect log'}
} catch {
 $state.Error=$_.Exception.Message
} finally {
 if($null-ne$serverProcess){$serverProcess.Refresh();if(-not$serverProcess.HasExited){Stop-Process -Id $serverProcess.Id -Force};$state.OwnServerStopped=$true}
 $state.CompletedUTC=[DateTime]::UtcNow.ToString('o')
 $state|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $probeDirectory 'hardware_probe_result.json') -Encoding UTF8
}
$state|ConvertTo-Json -Depth 6
