param([switch]$Rtl)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location $root
try {
 $exe=Join-Path $env:TEMP 'raw9_record_test.exe'
 & 'D:\winlibs\mingw64\bin\gcc.exe' -O2 -Wall -Wextra -Werror -Isw -Iprofiles/raw9_128k/sw profiles/raw9_128k/tests/record_test.c profiles/raw9_128k/sw/raw9_record.c sw/pdm_stream.c -o $exe
 if($LASTEXITCODE){throw 'Compile failed'}
 & $exe;if($LASTEXITCODE){throw 'Recorder test failed'}
 & 'D:\winlibs\mingw64\bin\gcc.exe' -O2 -Wall -Wextra -Werror -Iprofiles/raw9_128k/sw profiles/raw9_128k/tests/tx_test.c -o "$env:TEMP\raw9_tx_test.exe"
 if($LASTEXITCODE){throw 'TX compile failed'}
 & "$env:TEMP\raw9_tx_test.exe";if($LASTEXITCODE){throw 'TX test failed'}
 & 'D:\Python\python.exe' -B profiles/raw9_128k/tests/receive_test.py
 if($LASTEXITCODE){throw 'Receiver test failed'}
 if($Rtl){
  $out=Join-Path $env:TEMP ('raw9_xsim_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $out | Out-Null
  Push-Location $out
  try {
   $bin='E:\Vivado2020.2\Vivado\2020.2\bin'
   $files=@('profiles/raw9_128k/rtl/raw9_clkgen.v','profiles/raw9_128k/rtl/raw9_rx.v','profiles/raw9_128k/rtl/raw9_frontend.v','rtl/array/rv32_pdm_cic.v','profiles/raw9_128k/tests/clock_tb.v','profiles/raw9_128k/tests/rx_tb.v')|ForEach-Object{Join-Path $root $_}
   & "$bin\xvlog.bat" @files;if($LASTEXITCODE){throw 'xvlog failed'}
   foreach($top in @('clock_tb','rx_tb')){
    & "$bin\xelab.bat" $top -s $top --timescale 1ns/1ps;if($LASTEXITCODE){throw 'xelab failed'}
    & "$bin\xsim.bat" $top -runall;if($LASTEXITCODE){throw 'xsim failed'}
   }
  }finally{Pop-Location}
 }
 Write-Host 'RAW9_OFFLINE_CHECKS_PASS; no physical hardware accessed.'
}finally{Pop-Location}
