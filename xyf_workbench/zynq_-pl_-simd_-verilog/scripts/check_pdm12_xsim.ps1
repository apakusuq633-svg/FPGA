param([string]$Tag='m6_20261016_xsim')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$out=Join-Path $root ('build\'+$Tag)
if(Test-Path -LiteralPath $out){throw 'Use a new output tag'}
New-Item -ItemType Directory -Path $out | Out-Null
$tool=$(if($env:VIVADO_BIN_DIR){$env:VIVADO_BIN_DIR}else{'D:\Vivado\Vivado\2020.2\bin'})
$original=[IO.File]::ReadAllText((Join-Path $root 'tb\tb_pdm_array_rx.v'))
$reference=[regex]::Match($original,'(?s)module pdm_ref_cic.*?endmodule').Value
if(-not $reference){throw 'Reference module absent'}
[IO.File]::WriteAllText((Join-Path $out 'reference.v'),('`timescale 1ns/1ps'+"`n"+$reference))
Push-Location $out
try {
  & "$tool\xvlog.bat" --sv (Join-Path $root 'rtl\array\rv32_pdm_clkgen.v') (Join-Path $root 'rtl\array\rv32_pdm_cic.v') (Join-Path $root 'rtl\array\rv32_pdm_array_rx.v') (Join-Path $root 'rtl\array\rv32_chan_align.v') (Join-Path $out 'reference.v') (Join-Path $root 'tb\tb_pdm12_sync.v') *> compile.log
  if($LASTEXITCODE -ne 0){throw 'xvlog failed'}
  foreach($mode in @(0,1,2,3)) {
    $delay=if($mode -eq 3){140}else{108}
    $bench=[IO.File]::ReadAllText((Join-Path $root 'tb\tb_pdm12_sync.v')).Replace('parameter integer MODE=0;',"parameter integer MODE=$mode;").Replace('parameter integer DELAY_NS=108;',"parameter integer DELAY_NS=$delay;")
    # Raw diagnostic comparison only; production startup has a separate suite.
    $bench=$bench.Replace('rv32_pdm_array_rx #(', 'rv32_pdm_array_rx #(.MIC_STARTUP_CYCLES(0),.CIC_SETTLE_FRAMES(0),')
    [IO.File]::WriteAllText((Join-Path $out "bench$mode.v"),$bench)
    & "$tool\xvlog.bat" --sv "bench$mode.v" *> "compile$mode.log"
    if($LASTEXITCODE -ne 0){throw "xvlog failed mode $mode"}
    & "$tool\xelab.bat" tb_pdm12_sync -timescale 1ns/1ps -s "sync$mode" *> "elaborate$mode.log"
    if($LASTEXITCODE -ne 0){throw "xelab failed mode $mode"}
    & "$tool\xsim.bat" "sync$mode" -runall *> "run$mode.log"
    if($LASTEXITCODE -ne 0){throw "xsim failed mode $mode"}
    if(-not(Select-String -LiteralPath "run$mode.log" -Pattern 'PDM12_SYNC_PASS' -Quiet)){throw "PASS marker absent mode $mode"}
    if(Select-String -LiteralPath "run$mode.log" -Pattern 'FATAL|Error:' -Quiet){throw "Simulation error mode $mode"}
  }
  Write-Output 'M6_XSIM_PASS'
} finally {Pop-Location}
