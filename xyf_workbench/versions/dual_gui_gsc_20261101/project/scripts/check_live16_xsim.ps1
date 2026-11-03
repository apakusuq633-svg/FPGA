# Vivado Simulator alternative to the Icarus SoC test; no hardware download.
param([string]$ToolDir='D:\Vivado\Vivado\2020.2\bin',[switch]$Natural,[switch]$Debug4,[switch]$SpectraOnly,[switch]$Twelve,[switch]$CycleProfile,[switch]$RawCapture,[switch]$Numeric66,[switch]$TestSrp,[switch]$Transfer,[int]$SnapshotFrames=2,[string]$RunTag='',[string]$TransferBuild='build\localizer12')
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
if($CycleProfile -and (-not $Twelve -or $RawCapture -or $Natural -or $Debug4 -or $SpectraOnly)){throw 'CycleProfile requires Twelve and a built profiling firmware'}
$out=Join-Path $project $(if($CycleProfile){'build\das12_profile\xsim'}elseif($Twelve){'build\das12\xsim'}elseif($Debug4){'build\das4\xsim_quality'}elseif($SpectraOnly){'build\das16_loc\xsim_spectra'}elseif($Natural){'build\das16_loc\xsim_natural'}else{'build\das16_loc\xsim'})
$top=if($Twelve){'tb_live12_soc'}elseif($Debug4){'tb_live4_quality'}else{'tb_live16_soc'}
if($Transfer){
    if($CycleProfile -or $Numeric66 -or $RawCapture -or $TestSrp){throw 'Transfer is a separate SoC mode'}
    $out=Join-Path $project 'build\localizer12\xsim';$top='tb_localizer12_soc'
}
if($Numeric66){if(-not $CycleProfile -or -not $Twelve){throw 'Numeric66 requires Twelve and CycleProfile'};$out=Join-Path $project 'build\das12_profile\xsim_numeric66'}
if($RunTag){if($RunTag -notmatch '^[a-zA-Z0-9_]+$'){throw 'Invalid RunTag'};$out=Join-Path $project ('build\pdm12_runs\'+$RunTag)}
if($RawCapture) {
    if(-not $Twelve -or $Natural -or $Debug4 -or $SpectraOnly){throw 'RawCapture requires Twelve only'}
    $out=Join-Path $project 'build\das12\xsim_raw';$top='tb_raw_capture'
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
$rootUnix=$project.Replace('\','/')
$bench=[IO.File]::ReadAllText((Join-Path $project ('tb\'+$top+'.v'))).Replace('"build/','"'+$rootUnix+'/build/')
if($Transfer){
    $bench=$bench.Replace('parameter WINDOWS=4;',"parameter WINDOWS=$SnapshotFrames;")
    $transferRoot=Join-Path $project $TransferBuild
    $firmwareManifest=Get-Content -Raw (Join-Path $transferRoot 'build_manifest.json') | ConvertFrom-Json
    if(-not $firmwareManifest.test_transfer -or $firmwareManifest.transfer_windows -ne $SnapshotFrames){throw 'Transfer firmware/window count mismatch'}
    New-Item -ItemType Directory -Force (Join-Path $out 'fw') | Out-Null
    Copy-Item (Join-Path $transferRoot 'fw\*') (Join-Path $out 'fw')
    Copy-Item (Join-Path $transferRoot 'build_manifest.json') $out
    Copy-Item (Join-Path $project 'build\strict_overlap\vectors') (Join-Path $out 'vectors') -Recurse -Force
    $bench=$bench.Replace($rootUnix+'/build/localizer12/fw/',($out.Replace('\','/')+'/fw/'))
    $bench=$bench.Replace($rootUnix+'/build/strict_overlap/vectors/',($out.Replace('\','/')+'/vectors/'))
}
if($RawCapture){$bench='`define RAW12'+"`n"+$bench}
$bench=$bench.Replace('n%4096==0','n%1024==0')
if($Twelve){$bench=$bench.Replace('localparam integer SNAPSHOT_FRAMES = 2;',"localparam integer SNAPSHOT_FRAMES = $SnapshotFrames;")}
if($Numeric66){$bench='`define LIVE12_NUMERIC66'+"`n"+$bench}
if($Numeric66){
    Copy-Item (Join-Path $project 'build\pdm12_numeric') (Join-Path $out 'numeric_reference') -Recurse -Force
    $bench=$bench.Replace($rootUnix+'/build/pdm12_numeric/',($out.Replace('\','/')+'/numeric_reference/'))
}
if($TestSrp){if(-not $Numeric66){throw 'TestSrp requires Numeric66'};$bench='`define LIVE12_TEST_SRP'+"`n"+$bench}
if($CycleProfile){$bench='`define LIVE12_PROFILE'+"`n"+$bench}
if($CycleProfile){
    New-Item -ItemType Directory -Force (Join-Path $out 'fw') | Out-Null
    Copy-Item (Join-Path $project 'build\das12_profile\fw\*') (Join-Path $out 'fw')
    Copy-Item (Join-Path $project 'build\das12_profile\build_manifest.json') $out
    if($TestSrp){
        $bm=Get-Content -Raw (Join-Path $out 'build_manifest.json') | ConvertFrom-Json
        if($bm.flags -notcontains '-DFW_TEST_SRP=1'){throw 'TestSrp firmware flag missing'}
        Copy-Item (Join-Path $project 'build\pdm12_test_srp') (Join-Path $out 'test_srp') -Recurse -Force
        $bench=$bench.Replace($rootUnix+'/build/pdm12_test_srp/',($out.Replace('\','/')+'/test_srp/'))
    }
    $bench=$bench.Replace($rootUnix+'/build/das12_profile/fw/',($out.Replace('\','/')+'/fw/'))
}
[IO.File]::WriteAllText((Join-Path $out ($top+'.v')),$bench)
$fft=[IO.File]::ReadAllText((Join-Path $project 'rtl\acoustic\rv32_fft_bfly.v')).Replace('"build/fft_tw.hex"','"'+$rootUnix+'/build/fft_tw.hex"')
$fft=$fft.Replace('  reg signed [15:0] xr2_q, xi2_q;',"  wire signed [15:0] xr, xi, xr2, xi2;`n  wire [31:0] rz_k, rz_m;`n  reg signed [15:0] xr2_q, xi2_q;")
$fft=$fft.Replace('wire signed [15:0] xr2 = xr2_s[15:0],  xi2 = xi2_s[15:0];','assign xr2 = xr2_s[15:0]; assign xi2 = xi2_s[15:0];')
$fft=[regex]::Replace($fft,'wire signed \[15:0\] xr\s*=\s*xr_s\[15:0\],\s*xi\s*=\s*xi_s\[15:0\];','assign xr = xr_s[15:0]; assign xi = xi_s[15:0];')
if(-not $fft.Contains('assign xr = xr_s[15:0]; assign xi = xi_s[15:0];')) {throw 'FFT forward declaration adapter did not preserve xr/xi assignments'}
$fft=$fft.Replace('wire [31:0] rz_k =','assign rz_k =').Replace('wire [31:0] rz_m =','assign rz_m =')
$fft=$fft.Replace('  reg [15:0] rz_mr_q, rz_mi_q;','')
$fft=$fft.Replace('  reg signed [15:0] xr2_q, xi2_q;',"  reg [15:0] rz_mr_q, rz_mi_q;`n  reg signed [15:0] xr2_q, xi2_q;")
[IO.File]::WriteAllText((Join-Path $out 'rv32_fft_bfly.v'),$fft)
$localizerRtl=[IO.File]::ReadAllText((Join-Path $project 'rtl\array\rv32_overlap_localizer.v')).Replace('"rtl/rom/pdm_hann_q14.hex"','"'+$rootUnix+'/rtl/rom/pdm_hann_q14.hex"')
[IO.File]::WriteAllText((Join-Path $out 'rv32_overlap_localizer.v'),$localizerRtl)
# XSim rejects a legacy forward declaration accepted by Icarus and synthesis.
$steer=[IO.File]::ReadAllText((Join-Path $project 'rtl\srp\rv32_steer_regs.v'))
$first=$steer.IndexOf('  localparam [2:0] Q_IDLE')
$last=$steer.IndexOf('  reg       geo_start;')+'  reg       geo_start;'.Length
$declarations=$steer.Substring($first,$last-$first)
$steer=$steer.Remove($first,$last-$first)
$insert=$steer.IndexOf('  wire               g_busy')
$steer=$steer.Insert($insert,$declarations+"`n")
[IO.File]::WriteAllText((Join-Path $out 'rv32_steer_regs.v'),$steer)
$soc=[IO.File]::ReadAllText((Join-Path $project 'rtl\soc\rv32_soc.v'))
$soc=$soc.Replace('  reg [LED_WIDTH-1:0] led_q;','')
$soc=$soc.Insert($soc.IndexOf('  wire [31:0] imem_addr;'),"  reg [LED_WIDTH-1:0] led_q;`n")
$declarations=''
foreach($match in [regex]::Matches($soc,'(?m)^  wire.*(?:beam_fir_valid|beam_fir_sample|beam_comp|beam_locked|pdm_capture_rdata|pdm_valid_raw|pdm_aligned|pdm_frame_cnt|pdm_frozen|pdm_raw|pdm_gain|pdm_en).*;$')) {
    $declarations+=$match.Value+"`n";$soc=$soc.Replace($match.Value,'')
}
$soc=$soc.Insert($soc.IndexOf('  wire [31:0] imem_addr;'),$declarations)
[IO.File]::WriteAllText((Join-Path $out 'rv32_soc.v'),$soc)
$execute=[IO.File]::ReadAllText((Join-Path $project 'rtl\core\rv32_execute_stage.v'))
$execute=$execute.Replace('  wire acou_sel;','').Replace('  wire fft_sel;','')
$execute=$execute.Insert($execute.IndexOf('  wire [31:0] forwarded_rs1;'),"  wire acou_sel, fft_sel;`n")
[IO.File]::WriteAllText((Join-Path $out 'rv32_execute_stage.v'),$execute)
$files=@(& rg --files (Join-Path $project 'rtl') | Where-Object {$_ -match '\.v$' -and $_ -notmatch 'rv32_(ps_top|ps_regs|ps_memif|axi_lite_slave)\.v$'})
$prj=@()
foreach($file in $files) {
    $target=if($file.EndsWith('rv32_fft_bfly.v')) {Join-Path $out 'rv32_fft_bfly.v'} elseif($file.EndsWith('rv32_steer_regs.v')) {Join-Path $out 'rv32_steer_regs.v'} elseif($file.EndsWith('rv32_soc.v')) {Join-Path $out 'rv32_soc.v'} elseif($file.EndsWith('rv32_execute_stage.v')) {Join-Path $out 'rv32_execute_stage.v'} else {$file}
    if($file.EndsWith('rv32_overlap_localizer.v')){$target=Join-Path $out 'rv32_overlap_localizer.v'}
    $prj+='verilog work "'+$target.Replace('\','/')+'"'
}
$prj+='sv work "'+(Join-Path $out ($top+'.v')).Replace('\','/')+'"'
[IO.File]::WriteAllLines((Join-Path $out 'soc.prj'),$prj)
$runInfo=@{time_utc=[DateTime]::UtcNow.ToString('o');tool_dir=$ToolDir;snapshot_frames=$SnapshotFrames;numeric66=[bool]$Numeric66;cycle_profile=[bool]$CycleProfile;raw_capture=[bool]$RawCapture;transfer=[bool]$Transfer;bench_sha256=(Get-FileHash (Join-Path $out ($top+'.v'))).Hash}
$runInfo | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $out 'run_manifest.json')
$env:TEMP=Join-Path $project 'build\xilinx_temp';$env:TMP=$env:TEMP
New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
Push-Location $out
try {
    & (Join-Path $ToolDir 'xelab.bat') -relax -prj soc.prj -i (Join-Path $project 'rtl') ('work.'+$top) -s live16_soc -debug off -log elaboration.log *> elaboration_console.log
    if($LASTEXITCODE -ne 0) {throw 'XSim elaboration failed: see elaboration_console.log'}
    $simArgs=@('live16_soc','-runall','-log','simulation.log')
    if($Natural) {$simArgs+=@('-testplusarg','natural')}
    if($SpectraOnly) {$simArgs+=@('-testplusarg','spectra_only')}
    & (Join-Path $ToolDir 'xsim.bat') @simArgs *> simulation_console.log
    $log=[IO.File]::ReadAllText((Join-Path $out 'simulation.log'))
    $marker=if($Twelve){'LIVE12_SOC_PASS'}elseif($Debug4){'LIVE4_QUALITY_SOC_PASS'}elseif($SpectraOnly){'LIVE16_SPECTRA_PASS'}elseif($Natural){'LIVE16_NATURAL_PASS'}else{'LIVE16_SOC_PASS'}
    if($Transfer){$marker='LOCALIZER12_SOC_PASS'}
    if($RawCapture){$marker='RAW_CAPTURE_SOC_PASS'}
    if($LASTEXITCODE -ne 0 -or -not $log.Contains($marker)) {throw 'XSim SoC acceptance failed: see simulation.log'}
    Write-Host $(if($Transfer){'LOCALIZER12_XSIM_PASS'}elseif($RawCapture){'RAW_CAPTURE_XSIM_PASS'}elseif($CycleProfile){'LIVE12_PROFILE_XSIM_PASS'}elseif($Twelve){'LIVE12_XSIM_PASS'}elseif($Debug4){'LIVE4_QUALITY_XSIM_PASS'}elseif($Natural){'LIVE16_XSIM_NATURAL_PASS'}else{'LIVE16_XSIM_PASS'})
} finally {Pop-Location}
