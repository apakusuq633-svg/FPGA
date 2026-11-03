<# Run .\scripts\run_iverilog.ps1 from PowerShell to build and run every testbench under build/.

This is the quick simulation-only entry point; .\scripts\verify.ps1 is the real gate (it also
runs yosys, the manifest check and the PS compile checks). Both must be run from any directory.

The testbench list lives in ONE place below. The native and WSL paths used to carry two
hand-maintained copies, and they had already drifted apart from scripts/filelist.f: four
testbenches were compiled by nothing and run by nothing here. Listing a TB in scripts/filelist.f does NOT run it -- `-s` elaborates
exactly one top and leaves the rest out -- so a testbench that no runner names is a testbench
that silently rots.

That is not hypothetical: by 2026-09-22 the list below had drifted AGAIN and was missing
eleven testbenches, including the entire acoustic-localization chain (tb_fw_smoke, tb_fw_fft,
tb_fw_gcc, tb_fw_srp, tb_srp_scan, tb_xspec_phat, tb_acoustic_ext, tb_fft_addr, tb_fft_bfly)
plus tb_chan_align. So the list is now reconciled against tb/*.v at the
end of this script and any TB missing from it is reported loudly. Add the name here whenever
you add a tb/*.v.

Note the exit code alone is not a verdict: every TB ends with a bare $finish, so vvp returns 0
even when the test failed. verify.ps1 additionally requires a PASS: line and rejects any FAIL:
line; this quick script only surfaces the output, so read it.
#>
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$buildDir = Join-Path $projectRoot 'build'
$fileList = Join-Path $projectRoot 'scripts\filelist.f'

$tbs = @(
    'tb_rv32_units',
    'tb_rv32_soc',
    'tb_rv32_ps',
    'tb_led_demo',
    'tb_vec_unit',
    'tb_vec_core',
    'tb_chan_align',
    'tb_pdm_array_rx',
    'tb_pdm_capture',
    'tb_xspec_phat',
    'tb_srp_scan',
    'tb_steer',
    'tb_steer_regs',
    'tb_fw_smoke',
    'tb_fw_fft',
    'tb_fw_gcc',
    'tb_fw_srp',
    'tb_acoustic_ext',
    'tb_fft_addr',
    'tb_fft_bfly'
)

# Reconciliation: a tb/*.v that exists on disk but is not listed above is a TB nobody runs
# (the pitfall described at the top of this file). Keep this line ASCII: PowerShell 5.1
# decodes a BOM-less .ps1 with the system codepage, so non-ASCII bytes corrupt the script.
$onDisk = Get-ChildItem (Join-Path $projectRoot 'tb') -Filter 'tb_*.v' -ErrorAction SilentlyContinue |
          ForEach-Object { $_.BaseName }
$missing = @($onDisk | Where-Object { $tbs -notcontains $_ })
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host "WARNING: $($missing.Count) testbench(es) under tb/ are NOT in the list above," -ForegroundColor Yellow
    Write-Host "         so nothing runs them: $($missing -join ', ')" -ForegroundColor Yellow
    Write-Host '         Add them to $tbs in this file (see the header).' -ForegroundColor Yellow
}

if ((Get-Command iverilog -ErrorAction SilentlyContinue) -and
    (Get-Command vvp -ErrorAction SilentlyContinue)) {
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    Push-Location $projectRoot
    try {
        foreach ($tb in $tbs) {
            & iverilog -g2005 -I rtl -s $tb -o (Join-Path $buildDir "$tb.vvp") -c $fileList
            if ($LASTEXITCODE -ne 0) { throw "$tb compilation failed." }
            & vvp (Join-Path $buildDir "$tb.vvp")
            if ($LASTEXITCODE -ne 0) { throw "$tb failed." }
        }
    } finally {
        Pop-Location
    }
    exit 0
}

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    $driveLetter = $projectRoot.Substring(0, 1).ToLowerInvariant()
    $pathRemainder = $projectRoot.Substring(2).Replace('\', '/')
    $linuxProjectRoot = "/mnt/$driveLetter$pathRemainder"
    # Same list, same order: built from $tbs so the two paths cannot disagree again.
    $linuxCommand = "cd '$linuxProjectRoot' && mkdir -p build"
    foreach ($tb in $tbs) {
        $linuxCommand += " && iverilog -g2005 -I rtl -s $tb" +
            " -o build/$tb.vvp -c scripts/filelist.f" +
            " && vvp build/$tb.vvp"
    }
    & wsl sh -lc $linuxCommand
    if ($LASTEXITCODE -ne 0) { throw 'WSL simulation failed.' }
    exit 0
}

throw 'Neither native Icarus Verilog nor WSL is available.'
