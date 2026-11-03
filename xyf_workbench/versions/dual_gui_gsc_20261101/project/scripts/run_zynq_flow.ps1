# Run the Zynq flow (40 MHz, the product configuration), with retries.
#
# WARNING: **the retry did NOT fix the 2026-09-22 failure.** Nine consecutive runs all
#   hung in create_bd_design, reporting that
#   data/rsb/busdef/interrupt_signal/busdef.tcl does not exist -- while that 510-byte
#   file was right there, readable by Windows, and sourceable by a plain Vivado Tcl.
#   See the second section of docs/issues/018 (it lists every branch that was guessed
#   at and then ruled out). **Do not treat this script as the fix for that problem.**
#
# So why keep it? Two reasons.
#   1. Separate "the BD environment flaked" from "something is actually wrong" -- the
#      latter will not be cured by six retries, so stop early instead of reporting a
#      real bug as an environment problem.
#   2. **The moment a run does get past the BD, snapshot the project immediately**
#      (vivado_zynq_good). Otherwise the next round's `create_project -force` deletes
#      it -- and it may be the only success in dozens of attempts.
#
# Usage (**PowerShell only**, see CLAUDE.md / issues/018):
#     & scripts\run_zynq_flow.ps1
#
# Success is the string SYNTH_OK in the log (printed at the end of
# build/vfft_timing.tcl), **not the exit code** -- Vivado exits 0 even when the Tcl
# never reached an explicit exit.
#
# Keep this file ASCII-only: scripts/check_ps_apps.py enforces it, because PowerShell
# 5.1 decodes a BOM-less .ps1 with the system codepage (cp936 here) and non-ASCII
# bytes corrupt the script.

param(
    [int]$MaxTries = 6
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tcl  = Join-Path $root 'scripts\run_zynq_flow.tcl'
$log  = Join-Path $root 'build\das8\zynq_flow.log'
$jou  = Join-Path $root 'build\das8\zynq_flow.jou'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'build\das8') | Out-Null
$viv  = 'D:\Vivado\Vivado\2020.2\bin\vivado.bat'

# build/ is gitignored, so build/vfft_timing.tcl does not survive a clean checkout --
# and nothing regenerates it. It used to be the only accepted path, so a fresh clone
# made this script throw "missing build\vfft_timing.tcl" before doing anything.
# The flow itself lives in scripts/run_zynq_flow.tcl; fall back to it.
if (-not (Test-Path $tcl)) {
    $tcl = Join-Path $root 'scripts\run_zynq_flow.tcl'
    Write-Host "build\vfft_timing.tcl absent - using scripts\run_zynq_flow.tcl"
}
if (-not (Test-Path $tcl)) { throw "missing $tcl" }
if (-not (Test-Path $viv)) { throw "missing $viv" }

for ($try = 1; $try -le $MaxTries; $try++) {
    # Concurrent runs corrupt the IP design_assist cache (issues/018, first section),
    # so check before every round.
    $busy = Get-Process vivado -ErrorAction SilentlyContinue
    if ($busy) {
        Write-Host "attempt $try/$MaxTries : another vivado is running (pid $($busy.Id -join ',')) - waiting for it"
        $busy | Wait-Process
    }

    Write-Host "attempt $try/$MaxTries : launching vivado"

    # Launch through vivado.bat so its own redirection applies; stderr is not
    # redirected here (PowerShell 5.1 wraps every line of a native command's 2>&1 into
    # an ErrorRecord and sets $? to false).
    & $viv -mode batch -source $tcl -log $log -journal $jou | Out-Null

    if (-not (Test-Path $log)) { Write-Host "  no log produced"; continue }

    # Did the BD get built? Judge by the size of ps_pl.bd -- a failed run leaves a
    # 320-byte shell (a side effect of the first issues/018 attempt), a real BD is tens
    # of KB. This threshold was measured, not guessed.
    $bd    = Join-Path $root 'vivado_zynq\rv32_zynq.srcs\sources_1\bd\ps_pl\ps_pl.bd'
    $bdOk  = (Test-Path $bd) -and ((Get-Item $bd).Length -gt 10000)
    if ($bdOk) {
        $good = Join-Path $root 'vivado_zynq_good'
        if (Test-Path $good) { Remove-Item $good -Recurse -Force }
        Copy-Item (Join-Path $root 'vivado_zynq') $good -Recurse -Force
        Write-Host "  BD is real ($((Get-Item $bd).Length) B) - snapshotted to vivado_zynq_good"
    } else {
        Write-Host "  BD is a shell or absent - not snapshotting"
    }

    # Match the bare marker: scripts/run_zynq_flow.tcl prints "SYNTH_OK" while the old
    # build/vfft_timing.tcl wrapper printed "==> SYNTH_OK". Accepting both is what makes
    # the fallback above actually usable.
    if (Select-String -Path $log -Pattern 'SYNTH_OK' -Quiet) {
        Write-Host "attempt $try/$MaxTries : SYNTH_OK"
        exit 0
    }

    # issues/039 first: a native crash in the Tcl layer prints NO ERROR line anywhere, so
    # the $hardErr pattern below can never see it -- every module synthesizes fine and then
    # the process dies with 'TclStackFree: incorrect freePtr'. Left undetected it looks
    # exactly like a BD flake, and this script burns all six retries (~20 min) on it.
    # The signature is in the sub-run logs, not in $log.
    if (Select-String -Path $log -Pattern 'did not reach 100%' -Quiet) {
        $runs = Join-Path $root 'vivado_zynq\rv32_zynq.runs'
        $crash = $false
        if (Test-Path $runs) {
            $crash = [bool](Get-ChildItem $runs -Recurse -Filter 'runme.log' -ErrorAction SilentlyContinue |
                            Select-String -Pattern 'TclStackFree' -Quiet)
        }
        if ($crash) {
            Write-Host "  native crash in the Tcl layer (TclStackFree) - that is docs/issues/039"
            Write-Host "  (environment, kills a 4-line blink too). Retrying cannot help; stopping."
            exit 1
        }
    }

    # Separate "the BD environment flaked" from "something is actually wrong". Retry the
    # former per issues/018; the latter will not be cured by retrying, so stop -- otherwise
    # a real bug gets retried six times and then reported as an "environment problem".
    $bdFlake = Select-String -Path $log -Pattern 'couldn''t read file|\[BD 41-6[89]\]' -Quiet
    $hardErr = Select-String -Path $log -Pattern '^ERROR: \[(Synth|Common 17-69|Vivado|Design|Netlist|Place|Route)' -Quiet

    if ($hardErr -and -not $bdFlake) {
        Write-Host "  hard error (not a BD-init flake) - stopping, see $log"
        exit 1
    }

    Write-Host "  BD init flaked (see issues/018); retrying"
}

Write-Host "gave up after $MaxTries attempts - see $log"
exit 1
