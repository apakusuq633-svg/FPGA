# scripts/verify.ps1 -- automated verification for the RV32I five-stage pipeline.
#
# WARNING -- DO NOT EDIT rtl/ OR tb/ WHILE THIS SCRIPT IS RUNNING.
#   Every check recompiles the CURRENT rtl/, so a half-applied edit shows up as a
#   compile error that looks like a real failure, and which checks fail depends on
#   how far you got. Hit for real on 2026-10-04: a run started mid-edit reported
#   four checks (tb_fw_gcc / tb_fw_srp / tb_fft_bfly / generated tops) all failing
#   with "Unable to bind wire/reg/memory", pointing at the signal being added.
#   All four were false -- the other 21 had passed.  Edit first, then run.
#   Keep this file ASCII-only -- see the NOTE below, and check 14 enforces it.
#
# Runs twenty checks in order (numbers 9, 10, 13, 15 and 16 were retired on
# 2026-10-06 together with the ANC / I2S subsystem; the survivors keep their original
# numbers -- see the APPENDED-never-renumbered rule below):
#   1. manifest integrity  scripts/filelist.f matches the .v files under rtl/
#   2. no clock-gating     rtl/ and tb/ must not reference ICG constructs
#   3. single clock net    every edge-sensitive block uses posedge clk_i / negedge rst_n_i
#   4. RV32I unit tests    iverilog + vvp
#   5. SoC smoke test      iverilog + vvp
#   6. no latches          yosys assertion, both tops (a gated clock cell reappearing fails here)
#   7. PS-PL AXI test      iverilog + vvp
#   8. bare-PL LED demo    iverilog + vvp, real sw/led_demo_tb.hex preloaded into ITCM
#  11. vector unit          iverilog + vvp, rv32_vec_unit: tap mapping incl. cross-pass borrow
#  12. OP-V through the core iverilog + vvp, real OP-V firmware in rv32_soc's ITCM
#  14. PS A9#0 compile    scripts/check_ps_apps.py: host gcc -fsyntax-only on every
#                          surviving PS source, plus the PDM window cross-check
#
# Item 23 is the localization accelerators. The two localization-specific blocks
# (rv32_srp_scan, rv32_xspec_phat) used to be testbench-only; rv32_srp_regs /
# rv32_xsp_regs now put them behind a register window on both the core MMIO pages
# (0x8000 / 0x9000) and the PS AXI windows (0x400 / 0x500), and the custom-1
# (opcode 0x2B) doorbell starts them from the core. It is also the FIRST item to
# actually RUN tb_srp_scan / tb_xspec_phat: both were in filelist.f so they were
# always compiled, but no item ever selected them as a top, so they never ran.
# Listing a TB makes it compile, not pass: -s only elaborates the selected top.
#
# Items are APPENDED, never renumbered: their numbers are referenced from the README,
# from testbench headers and from commit messages, so a renumber would silently point
# old prose at the wrong check.
#
# Exit code 0 when everything passes, 1 otherwise.
# Uses native iverilog/vvp/yosys when present, otherwise falls back to WSL.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads a .ps1 with no
# BOM using the system ANSI codepage, so non-ASCII bytes here corrupt the script.

param(
    # Checks 27 and 28 are the whole-machine speedup pair. 27 runs two full RTL
    # simulations (several minutes each), so it is skippable while iterating on
    # something else -- but it must NOT be skipped for a release/acceptance run.
    [switch]$SkipWholeMachine
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$buildDir    = Join-Path $projectRoot 'build'
$fileList    = Join-Path $projectRoot 'scripts\filelist.f'
$rtlDir      = Join-Path $projectRoot 'rtl'
$tbDir       = Join-Path $projectRoot 'tb'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$results = New-Object System.Collections.ArrayList

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    [void]$results.Add([pscustomobject]@{ Name = $Name; Passed = $Passed; Detail = $Detail })
    if ($Passed) {
        Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
    }
    if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray }
}

# --------------------------------------------------------------- toolchain
$nativeReady = (Get-Command iverilog -ErrorAction SilentlyContinue) -and
               (Get-Command vvp      -ErrorAction SilentlyContinue) -and
               (Get-Command yosys    -ErrorAction SilentlyContinue)

$useWsl = $false
if (-not $nativeReady) {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        $useWsl = $true
    } else {
        throw 'Need native iverilog/vvp/yosys, or a working WSL.'
    }
}

$linuxRoot = ''
if ($useWsl) {
    $driveLetter = $projectRoot.Substring(0, 1).ToLowerInvariant()
    $linuxRoot   = "/mnt/$driveLetter" + $projectRoot.Substring(2).Replace('\', '/')
}

# Run one POSIX command line from the project root (via WSL or a native shell).
# Returns @{ Code = <exit code>; Output = <captured stdout+stderr> }.
function Invoke-Posix {
    param([string]$Command)
    $output = @()
    if ($useWsl) {
        $output = @(& wsl sh -lc "cd '$linuxRoot' && $Command" 2>&1)
    } else {
        Push-Location $projectRoot
        try { $output = @(& sh -lc $Command 2>&1) } finally { Pop-Location }
    }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output }
}

# Print a tool's captured output, indented, so the testbench PASS lines stay visible.
function Show-Output {
    param($Output)
    foreach ($line in @($Output)) {
        $text = [string]$line
        if ($text.Trim().Length -gt 0) {
            Write-Host ("         {0}" -f $text.TrimEnd()) -ForegroundColor DarkGray
        }
    }
}

# The testbenches end with a bare $finish, so vvp always exits 0 -- a functional
# FAIL still looks like success if we only check the exit code. Require the PASS
# line and reject any FAIL line.
function Test-SimPassed {
    param($Output, [int]$Code)
    if ($Code -ne 0) { return $false }
    $fail = @($Output | Where-Object { [string]$_ -match 'FAIL:' }).Count
    $pass = @($Output | Where-Object { [string]$_ -match 'PASS:' }).Count
    return (($fail -eq 0) -and ($pass -gt 0))
}

if ($useWsl) {
    Write-Host "toolchain: WSL ($linuxRoot)" -ForegroundColor Cyan
} else {
    Write-Host "toolchain: native iverilog/vvp/yosys" -ForegroundColor Cyan
}
Write-Host ''

# --------------------------------------------------- 1. manifest integrity
Write-Host '== 1. manifest integrity' -ForegroundColor Cyan
try {
    $listed = @(Get-Content -LiteralPath $fileList |
                Where-Object { $_ -match '\S' } |
                ForEach-Object { $_.Trim() })

    $missing = @($listed | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $projectRoot $_))
    })

    $prefixLen = $projectRoot.Length + 1
    $onDisk = @(Get-ChildItem -Path $rtlDir -Recurse -Filter '*.v' | ForEach-Object {
        $_.FullName.Substring($prefixLen).Replace('\', '/')
    })

    $unlisted = @($onDisk | Where-Object { $listed -notcontains $_ })

    # gen_synth_top.tcl's two procs emit the rv32_soc port list as HARDCODED strings, so
    # there are two independent copies of that list. Adding a port to rv32_soc and missing
    # one proc makes the generated top not match, and the error only shows up at Vivado
    # elaboration, looking nothing like "one port is missing".
    # Compare them here: pull the *_i/_o identifiers out of rv32_soc's port list and diff
    # against the .port(...) lines of each proc.
    # Read as UTF8: these files carry Chinese comments, and PS 5.1 decodes a BOM-less
    # file with the system ANSI codepage by default. That does not just produce mojibake
    # -- cp936 pairs bytes, so a comment line with an odd byte count can swallow the
    # newline that follows it, gluing the next line onto the comment. Anything that
    # searches across line boundaries then silently finds nothing.
    $socSrc  = Get-Content -LiteralPath (Join-Path $projectRoot 'rtl\soc\rv32_soc.v') -Raw -Encoding UTF8
    $socHdr  = $socSrc.Substring(0, $socSrc.IndexOf(');'))
    $socPorts = @([regex]::Matches($socHdr, '\b([a-z][a-z0-9_]*_[io])\b') |
                  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $tclSrc = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts\gen_synth_top.tcl') -Raw -Encoding UTF8
    # Split on the proc name, never on a newline (see the encoding note above).
    $idxSynth = $tclSrc.IndexOf('proc gen_synth_top')
    $idxBoard = $tclSrc.IndexOf('proc gen_board_top')
    $portBad = @()
    foreach ($procName in @('gen_synth_top', 'gen_board_top')) {
        if ($procName -eq 'gen_synth_top') {
            $seg = $tclSrc.Substring($idxSynth, $idxBoard - $idxSynth)
        } else {
            $seg = $tclSrc.Substring($idxBoard)
        }
        $genPorts = @([regex]::Matches($seg, 'puts \$fp "\s*\.([a-z][a-z0-9_]*_[io])\s*\(') |
                      ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $diff = @(Compare-Object $socPorts $genPorts)
        if ($diff.Count -gt 0) {
            $portBad += ("$procName : " + (($diff | ForEach-Object {
                "$($_.InputObject)$(if ($_.SideIndicator -eq '<=') { '(RTL only)' } else { '(top only)' })"
            }) -join ', '))
        }
    }

    if ($missing.Count -gt 0) {
        Add-Result 'manifest integrity' $false ("listed but missing on disk: " + ($missing -join ', '))
    } elseif ($unlisted.Count -gt 0) {
        Add-Result 'manifest integrity' $false ("on disk but not listed: " + ($unlisted -join ', '))
    } elseif ($portBad.Count -gt 0) {
        Add-Result 'manifest integrity' $false ("gen_synth_top.tcl port lists diverge from rv32_soc -- " + ($portBad -join ' | '))
    } else {
        Add-Result 'manifest integrity' $true ("$($listed.Count) entries, all $($onDisk.Count) rtl/ .v files accounted for; both generated tops match rv32_soc's $($socPorts.Count) ports")
    }
} catch {
    Add-Result 'manifest integrity' $false $_.Exception.Message
}

# ------------------------------------------------------- 2. no clock gating
Write-Host '== 2. no clock gating' -ForegroundColor Cyan
try {
    $banned = 'rv_icg', 'gated_clk', 'en_latched', 'en_latch', 'clk_o'
    $hits = @()
    foreach ($dir in @($rtlDir, $tbDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -Path $dir -Recurse -Include '*.v', '*.vh' | ForEach-Object {
            $file = $_
            $lineNo = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $lineNo++
                foreach ($token in $banned) {
                    if ($line -match ("\b" + [regex]::Escape($token) + "\b")) {
                        $hits += ("{0}:{1} {2}" -f $file.Name, $lineNo, $token)
                    }
                }
            }
        }
    }
    if ($hits.Count -gt 0) {
        Add-Result 'no clock gating' $false ($hits -join '; ')
    } else {
        Add-Result 'no clock gating' $true 'no ICG-related identifiers in rtl/ or tb/'
    }
} catch {
    Add-Result 'no clock gating' $false $_.Exception.Message
}

# ----------------------------------------------------- 3. single clock net
Write-Host '== 3. single clock net' -ForegroundColor Cyan
try {
    $edgeRe = [regex]'(pos|neg)edge\s+([A-Za-z_][A-Za-z_0-9]*)'
    $bad = @()
    $edgeCount = 0
    Get-ChildItem -Path $rtlDir -Recurse -Filter '*.v' | ForEach-Object {
        $file = $_
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            $lineNo++
            foreach ($m in $edgeRe.Matches($line)) {
                $edgeCount++
                $kind = $m.Groups[1].Value
                $sig  = $m.Groups[2].Value
                if ($kind -eq 'pos' -and $sig -ne 'clk_i') {
                    $bad += ("{0}:{1} posedge {2}" -f $file.Name, $lineNo, $sig)
                }
                if ($kind -eq 'neg' -and $sig -ne 'rst_n_i') {
                    $bad += ("{0}:{1} negedge {2}" -f $file.Name, $lineNo, $sig)
                }
            }
        }
    }
    if ($bad.Count -gt 0) {
        Add-Result 'single clock net' $false ("non-clk_i clock edges: " + ($bad -join '; '))
    } else {
        Add-Result 'single clock net' $true "$edgeCount clock edges, all posedge clk_i / negedge rst_n_i"
    }
} catch {
    Add-Result 'single clock net' $false $_.Exception.Message
}

# ------------------------------------------------------------- 4. unit tests
Write-Host '== 4. RV32I unit tests' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_rv32_units -o build/tb_rv32_units.vvp -c scripts/filelist.f && vvp build/tb_rv32_units.vvp'
    Show-Output $r.Output
    Add-Result 'RV32I unit tests' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'RV32I unit tests' $false $_.Exception.Message
}

# --------------------------------------------------------- 5. SoC smoke test
Write-Host '== 5. SoC smoke test' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_rv32_soc -o build/tb_rv32_soc.vvp -c scripts/filelist.f && vvp build/tb_rv32_soc.vvp'
    Show-Output $r.Output
    Add-Result 'SoC smoke test' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'SoC smoke test' $false $_.Exception.Message
}

# ------------------------------------------------------------- 6. no latches
Write-Host '== 6. no latches' -ForegroundColor Cyan
try {
    if (-not (Test-Path -LiteralPath $buildDir)) {
        New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    }

    # Generate the yosys script from the manifest so this check does not depend
    # on any pre-existing file under build/.
    $rtlEntries = @(Get-Content -LiteralPath $fileList |
                    Where-Object { $_ -match '^\s*rtl/' } |
                    ForEach-Object { $_.Trim() })

    $ysPath = Join-Path $buildDir 'verify_latch.ys'
    # Two passes, one per top. `hierarchy -top rv32_soc` prunes everything not
    # reachable from that top, so the PS-PL top would escape the check entirely
    # and its latches would never be seen. `design -reset` between the passes is
    # more portable than passing two -top flags, which older yosys rejects.
    $ysLines = @(
        ('read_verilog -I rtl ' + ($rtlEntries -join ' '))
        'hierarchy -top rv32_soc'
        'proc'
        'opt'
        # Must use the word-level latch cell types. The gate-level $_DLATCH_*
        # names only exist after techmap, so at this proc/opt stage they match
        # nothing and the assertion would pass vacuously.
        'select -assert-none t:$dlatch t:$adlatch t:$dlatchsr t:$sr'
        'design -reset'
        ('read_verilog -I rtl ' + ($rtlEntries -join ' '))
        'hierarchy -top rv32_ps_top'
        'proc'
        'opt'
        'select -assert-none t:$dlatch t:$adlatch t:$dlatchsr t:$sr'
    )
    Set-Content -LiteralPath $ysPath -Value $ysLines -Encoding ASCII

    $r = Invoke-Posix 'yosys build/verify_latch.ys > build/verify_latch.log 2>&1'
    $logPath = Join-Path $buildDir 'verify_latch.log'
    $latchLines = 0
    if (Test-Path -LiteralPath $logPath) {
        # Anchored regex on purpose: a -SimpleMatch substring would also match the
        # "No latch inferred for signal ..." lines, which are the passing case.
        $latchLines = @(Select-String -LiteralPath $logPath -Pattern '^\s*Latch inferred for signal').Count
    }

    if ($r.Code -ne 0) {
        Add-Result 'no latches' $false "yosys assertion failed, see build/verify_latch.log ($latchLines 'Latch inferred' lines)"
    } elseif ($latchLines -gt 0) {
        Add-Result 'no latches' $false "$latchLines latch(es) inferred, see build/verify_latch.log"
    } else {
        Add-Result 'no latches' $true 'no latch cells in the whole design'
    }
} catch {
    Add-Result 'no latches' $false $_.Exception.Message
}

# --------------------------------------------------------- 7. PS-PL AXI test
Write-Host '== 7. PS-PL AXI test' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_rv32_ps -o build/tb_rv32_ps.vvp -c scripts/filelist.f && vvp build/tb_rv32_ps.vvp'
    Show-Output $r.Output
    Add-Result 'PS-PL AXI test' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'PS-PL AXI test' $false $_.Exception.Message
}

# -------------------------------------------------- 8. bare-PL LED demo test
# Legacy register/ISA smoke only. Acoustic acceptance requires item 26 below.
# The first seven checks never touch this firmware, so only here do firmware encoding,
# MMIO decode and $readmemh preload get verified together.
Write-Host '== 8. bare-PL LED demo test' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_led_demo -o build/tb_led_demo.vvp -c scripts/filelist.f && vvp build/tb_led_demo.vvp'
    Show-Output $r.Output
    Add-Result 'bare-PL LED demo test' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'bare-PL LED demo test' $false $_.Exception.Message
}

# -------------------------------------------------- 11. vector unit (8-lane MAC)
# Drives rv32_vec_unit standalone: pokes the coefficient banks directly, pushes samples
# into the delay line, and asserts the tap mapping. The two load-bearing cases are
# x(n-1) and x(n-8) -- an off-by-one in the bank/word addressing silently shifts the
# whole delay line, and a shifted filter still "converges", just to the wrong thing.
Write-Host '== 11. vector unit (8-lane MAC)' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_vec_unit -o build/tb_vec_unit.vvp -c scripts/filelist.f && vvp build/tb_vec_unit.vvp'
    Show-Output $r.Output
    Add-Result 'vector unit (8-lane MAC)' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'vector unit (8-lane MAC)' $false $_.Exception.Message
}

# ------------------------------------------------- 11b. GSC interleaved onto the array
# The two items above prove the array is a correct FIR engine. This one proves the
# *GSC* fits in it: the 7 reference signals are INTERLEAVED into one delay line
# (position m = 7n + j), which collapses the 7-way adaptive filter into a single
# 112-tap FIR -- one delay line, one coefficient set. See docs/gsc_vec_design.md.
# The expectation is a closed form (448N+14560) chosen to be ASYMMETRIC in the ref
# index: a symmetric one cannot catch a permuted-ref bug, which is exactly how the
# first version of this TB fooled itself.
Write-Host '== 11b. GSC interleaved onto the 8-lane array' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_gsc_vec_map -o build/tb_gsc_vec_map.vvp -c scripts/filelist.f && vvp build/tb_gsc_vec_map.vvp'
    Show-Output $r.Output
    Add-Result 'GSC interleaved onto the 8-lane array' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'GSC interleaved onto the 8-lane array' $false $_.Exception.Message
}

# ------------------------------------------------- 12. OP-V through the core
# Item 11 drives the array standalone; this one drives it the way firmware will,
# from inside rv32_soc: decode of opcode 0x0B, rs1 forwarding into the array, the
# multi-cycle stall, and the writeback mux in the EX stage. Standalone passes say
# nothing about any of those -- the wire between the decoder and the array is
# exactly where a one-bit mistake stays silent (a wrong channel select reads an
# untouched bank, which is X, which is not "a wrong number", it is a wrong number
# that still looks plausible once it lands in a filter accumulator).
Write-Host '== 12. OP-V through the core' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_vec_core -o build/tb_vec_core.vvp -c scripts/filelist.f && vvp build/tb_vec_core.vvp'
    Show-Output $r.Output
    Add-Result 'OP-V through the core' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'OP-V through the core' $false $_.Exception.Message
}

# -------------------------------------------------- 14. PS A9#0 compile checks
# The stubs are compile-only: this is not BSP-link or board validation. It is the only
# host-side check four of the surviving PS sources ever get -- ps_main / ps_dualcore /
# ps_fft_test / ps_pdm cannot run anywhere but the board, so compiling them with the
# cstub headers is the whole of their coverage before Vitis sees them. It also holds the
# PDM window offsets against the RTL that decodes them (see check_pdm_window).
Write-Host '== 14. PS A9#0 compile checks (stage 4)' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'python3 scripts/check_ps_apps.py > build/verify_ps_compile.log 2>&1'
    $psLog = Join-Path $buildDir 'verify_ps_compile.log'
    if (Test-Path -LiteralPath $psLog) {
        Show-Output (Get-Content -LiteralPath $psLog -Encoding UTF8)
    }
    Show-Output $r.Output
    Add-Result 'PS A9#0 compile checks' ($r.Code -eq 0) 'see build/verify_ps_compile.log (compile only; no hardware execution)'
} catch {
    Add-Result 'PS A9#0 compile checks' $false $_.Exception.Message
}

# ------------------------------------------------- 17. PL firmware kernels (FFT / GCC-PHAT / SRP / DAS beamformer)
# Runs the real sw/fw/ build (ITCM + DTCM images) inside rv32_soc and compares each
# kernel's output against a bit-exact Python fixed-point model. Four TBs, one per
# kernel group; each also re-checks the earlier kernels, so any of them catches a
# regression anywhere in the chain.
#
# TWO images must be preloaded (ITCM_FILE and DTCM_FILE). Loading only ITCM runs fine
# and produces X for every constant and initialiser -- see docs/issues/031.
#
# NOTE on the word "DAS": fw_main.c section 5 has a *baseline fingerprint* that reuses
# the SRP kernel with a non-whitened R -- it stores a peak cell and a checksum, and is
# covered by tb_fw_srp. tb_fw_das covers the actual beamformer from README 26.1
# (fw_das.c): per-channel fractional delay from the real geometry, equal-weight sum,
# which is the thing that produces enhanced audio. Two different objects, one name.
#
# These tests share the deterministic acceptance binary, now using fixed FIR.
# Current whole-machine measurements are in docs/measurements.md section 17.
#
# !! Every tb_fw_* waits for the SAME final done marker, so **adding a kernel makes
# all of them slower, and any MAXC that was sized for the old firmware silently turns
# them red** without anyone touching them. That happened: four TBs sat at MAXC=4.2M
# (sized for the 3.35M pre-GSC round) and all four failed once GSC landed. See
# docs/issues/070-fw-tb-maxc-stale-after-new-kernel.md.
Write-Host '== 17. PL firmware kernels (FFT / GCC-PHAT / SRP / DAS beamformer)' -ForegroundColor Cyan
foreach ($tb in @('tb_fw_fft', 'tb_fw_gcc', 'tb_fw_srp', 'tb_fw_das')) {
    try {
        $r = Invoke-Posix ("iverilog -g2005 -I rtl -s {0} -o build/{0}.vvp -c scripts/filelist.f && vvp build/{0}.vvp" -f $tb)
        Show-Output $r.Output
        Add-Result ("PL firmware kernel: {0}" -f $tb) (Test-SimPassed $r.Output $r.Code) ''
    } catch {
        Add-Result ("PL firmware kernel: {0}" -f $tb) $false $_.Exception.Message
    }
}

# ------------------------------------------------- 18. acoustic DSP extension unit
# Drives rtl/acoustic/rv32_acoustic_ext.v standalone: VCMUL / VPHAT / VSUB / VRED2,
# each compared bit-for-bit against the fixed-point model, plus the cycle account that
# shows the operand transfer dominates (98.5%). Unit-level first, on purpose -- when
# this module was brought up, three of its four bugs would only have shown up inside
# the core as "the firmware's cross-spectrum is wrong", 2.8 million cycles away.
# See docs/issues/036.
Write-Host '== 18. acoustic DSP extension unit' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_acoustic_ext -o build/tb_acoustic_ext.vvp -c scripts/filelist.f && vvp build/tb_acoustic_ext.vvp'
    Show-Output $r.Output
    Add-Result 'acoustic DSP extension (VCMUL/VPHAT/VSUB/VRED2)' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'acoustic DSP extension (VCMUL/VPHAT/VSUB/VRED2)' $false $_.Exception.Message
}

# ------------------------------------------------- 19. VFFT (in-core 512-point FFT)
# Item 18's sibling for the FFT unit. Two TBs, on purpose:
#   tb_fft_addr  the address generator alone, all 2304 butterflies of the 9 stages,
#                checked cycle by cycle against a Python enumeration. This goes first
#                because an address bug yields "something that looks like a spectrum",
#                not a visibly absurd number -- comparing it against the golden would
#                not tell you whether the address or the butterfly was wrong.
#   tb_fft_bfly  the whole unit; its 513 bins are compared bit-for-bit against the
#                SAME golden the scalar firmware FFT passes (build/fw_fft_ref.hex),
#                so all the earlier verification is reused.
#   tb_fft_ifft  VFFT-inv (instruction bit instr[30]) and a full-scale forward frame.
#                Its golden comes from the SAME C source built for the host
#                (scripts/golden/fw_ifft_host.c), so "hardware == golden" means
#                "hardware == the scalar firmware". The full-scale frame is the
#                one that catches the 16-bit-context overflow in the split stage
#                (docs/issues/087): with the bug present this TB reports 2/513
#                mismatches, without it 0/513.
Write-Host '== 19. VFFT (in-core 512-point FFT)' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'bash scripts/golden/fw_ifft_host_check.sh'
    Show-Output $r.Output
    Add-Result 'VFFT: vector generation (host C golden)' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'VFFT: vector generation (host C golden)' $false $_.Exception.Message
}
foreach ($tb in @('tb_fft_addr', 'tb_fft_bfly', 'tb_fft_ifft')) {
    try {
        $r = Invoke-Posix ("iverilog -g2005 -I rtl -s {0} -o build/{0}.vvp -c scripts/filelist.f && vvp build/{0}.vvp" -f $tb)
        Show-Output $r.Output
        Add-Result ("VFFT: {0}" -f $tb) (Test-SimPassed $r.Output $r.Code) ''
    } catch {
        Add-Result ("VFFT: {0}" -f $tb) $false $_.Exception.Message
    }
}

# ------------------------------------------------- 20. PDM mic array front end
# The PDM mic array front end: 16 CIC channels, 1-bit sigma-delta in,
# 24-bit PCM out at the SAME fs = clk/1024 the whole downstream chain is locked to.
# The 24-bit wraparound accumulators are checked sample-by-sample against a 64-bit
# non-wrapping reference, and eight absolute values come from scripts/golden/pdm_decim.py
# (first established analytically, then confirmed by that model -- see the header there).
# The design numbers behind ORDER=3 / ACC_W=24 are in docs/pdm_array_spec.md.
Write-Host '== 20. PDM mic array front end' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_pdm_array_rx -o build/tb_pdm_array_rx.vvp -c scripts/filelist.f && vvp build/tb_pdm_array_rx.vvp'
    Show-Output $r.Output
    Add-Result 'PDM mic array front end (sinc^3/D=64, 8 & 16 ch)' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'PDM mic array front end (sinc^3/D=64, 8 & 16 ch)' $false $_.Exception.Message
}

# ------------------------------------------------- 21. PDM capture path to PS
# Item 20 is the front end alone; this is the path that actually reaches software:
# rv32_pdm_array_rx -> rv32_chan_align -> rv32_pdm_capture -> the 0x300 AXI window.
# The gain registers are checked to reset to 16384 (unity), NOT to chan_align's 0 --
# that 0 is mute, and a muted path still looks alive (frames, valid, all-zero data),
# so it reads as a dead microphone. See docs/issues/029.
# tb_pdm_capture uses N_CH=8, matching the current eight-input production topology.
# Item 20 retains coverage of the optional legacy dual-edge front end.
Write-Host '== 21. PDM capture path to PS' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'iverilog -g2005 -I rtl -s tb_pdm_capture -o build/tb_pdm_capture.vvp -c scripts/filelist.f && vvp build/tb_pdm_capture.vvp'
    Show-Output $r.Output
    Add-Result 'PDM capture path (dual bank, packing, drop, gain reset)' (Test-SimPassed $r.Output $r.Code) ''
} catch {
    Add-Result 'PDM capture path (dual bank, packing, drop, gain reset)' $false $_.Exception.Message
}

# ------------------------------------------- 22. generated tops actually compile
# Item 1 compares the PORT NAMES of rv32_soc against the two hardcoded lists in
# gen_synth_top.tcl -- it does not check the syntax of what those procs EMIT.
# A typo in a `puts` line (missing comma, wrong bit width, a name that matches no
# port) passes item 1 and only shows up inside Vivado, looking like something else
# entirely. This expands the puts lines offline (no tclsh on this machine, and
# Vivado's is a whole Vivado) and compiles the result.
Write-Host '== 22. generated tops compile' -ForegroundColor Cyan
try {
    # Do NOT use `$(find rtl -name "*.v")` here. This string travels PowerShell -> wsl.exe
    # -> `sh -lc`, and the inner double quotes end the outer quoted argument at the Windows
    # argument-parsing layer, so `sh` gets a truncated command and the file list is then
    # executed as a command list ("rtl/soc/rv32_soc.v: 1: module: not found").
    # Symptom: iverilog reports `Unknown module type: rv32_soc` and the check fails while
    # the same two iverilog lines pass when run by hand. docs/issues/055.
    # `rtl/*/*.v` is the same 58 files (nothing lives deeper than rtl/<dir>/).
    $r = Invoke-Posix 'python3 scripts/golden/expand_synth_top.py && iverilog -g2005 -I rtl -s rv32_synth_top -o build/gen_synth.vvp build/gen_synth.v rtl/*/*.v && iverilog -g2005 -I rtl -s rv32_board_top -o build/gen_board.vvp build/gen_board.v rtl/*/*.v && echo EXPAND_AND_COMPILE_OK'
    Show-Output $r.Output
    $ok = ($r.Code -eq 0) -and ($r.Output -match 'EXPAND_AND_COMPILE_OK') -and ($r.Output -notmatch 'error')
    Add-Result 'generated tops compile (synth + board)' $ok ''
} catch {
    Add-Result 'generated tops compile (synth + board)' $false $_.Exception.Message
}

# ------------------------------------- 23. localization accelerators
# The two localization blocks are no longer testbench-only. This item runs, in order:
#   tb_srp_scan / tb_xspec_phat  the blocks themselves (see the header note)
#   tb_srp_regs / tb_xspec_regs  the register windows, P bit-exact vs the golden,
#                                and the negative controls (a refused write must
#                                raise WERR instead of silently landing elsewhere)
#   tb_loc_core                  the custom-1 doorbell: fires EXACTLY once, does
#                                NOT stall (delta == 2 cycles against the same
#                                program without it, vs +5121 if it stalled), and
#                                a reserved funct3 still traps.
# The SRP vectors are build/ artifacts (build/ is gitignored) and both SRP TBs read
# them, so they are regenerated here every run: the default set is full size
# (28 pairs x 32x32, what tb_srp_scan drives) and srp4x256 is the size the SoC
# actually instantiates (4 pairs x 16x16, what tb_srp_regs drives).
Write-Host '== 23. localization accelerators' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'python3 scripts/golden/gen_srp_vectors.py && python3 scripts/golden/gen_srp_vectors.py --pairs 4 --grid-w 16 --out-prefix srp4x256'
    Show-Output $r.Output
    if ($r.Code -ne 0) { throw 'gen_srp_vectors.py failed (SRP TBs would read stale/missing vectors)' }
    foreach ($tb in @('tb_srp_scan', 'tb_xspec_phat', 'tb_srp_regs', 'tb_xspec_regs', 'tb_loc_core')) {
        $r = Invoke-Posix ("iverilog -g2005 -I rtl -s {0} -o build/{0}.vvp -c scripts/filelist.f && vvp build/{0}.vvp" -f $tb)
        Show-Output $r.Output
        Add-Result ("localization accelerator: " + $tb) (Test-SimPassed $r.Output $r.Code) ''
    }
} catch {
    Add-Result 'localization accelerators' $false $_.Exception.Message
}

# ------------------------------------- 24. beam steering (localization -> beamformer)
# The arrow between the two ends. rv32_steer turns a located grid cell into the 8
# per-mic alignment compensations the beamformer needs:
#
#     comp_m = tau_{0m} - min_j tau_{0j}
#
# i.e. it is derived from the SAME 7 pair delays the SRP block already uses, so the
# core has no isqrt and no divider -- 8 LUT reads, one min, 8 subtractions (19 cycles).
# rv32_steer_regs wraps it with the register window plus the section 26.5 policy:
# hysteresis (a one-frame excursion must not move the locked direction) and the
# ramping of a direction change (must not be an instant jump).
#
# Both TBs read build/steer_*.hex, and build/ is gitignored, so regenerate first --
# same reason item 23 regenerates the SRP vectors.
Write-Host '== 24. beam steering (localization -> beamformer)' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'python3 scripts/golden/gen_steer_vectors.py'
    Show-Output $r.Output
    if ($r.Code -ne 0) { throw 'gen_steer_vectors.py failed (steering TBs would read stale vectors)' }
    foreach ($tb in @('tb_steer', 'tb_steer_regs')) {
        $r = Invoke-Posix ("iverilog -g2005 -I rtl -s {0} -o build/{0}.vvp -c scripts/filelist.f && vvp build/{0}.vvp" -f $tb)
        Show-Output $r.Output
        Add-Result ("beam steering: " + $tb) (Test-SimPassed $r.Output $r.Code) ''
    }
} catch {
    Add-Result 'beam steering' $false $_.Exception.Message
}

# ------------------------------------------------- 25. PDM pinout cross-check
# The nine PDM signals are stated in more than one place (the xdc, board_io.md section 8,
# and the RTL header comment), and pdm_array_spec.md claims in writing that the first two
# agree "bit for bit" -- nothing checked that claim. They drifted once already: seven
# documents disagreed about whether the 8-channel array is wired to J3 or to J4, and the
# two connectors put PDM_CLK on DIFFERENT package pins (V16 vs W15). Wiring the array
# from the wrong table gives a board where nothing moves and nothing reports an error.
# See docs/issues/063. The script also gates PDM_CLK staying on J3.36 (the signal
# position adjacent to a ground return), the data pins keeping PULLDOWN true, one
# IOSTANDARD across all nine, and no second .xdc pinning a PDM port.
# Keep this comment ASCII: check_ps_apps.py decodes every scripts/*.ps1 as ASCII, because
# PS 5.1 would otherwise read a BOM-less file with the system codepage.
Write-Host '== 25. PDM pinout (xdc vs board_io section 8)' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'python3 scripts/check_pdm_pins.py'
    Show-Output $r.Output
    Add-Result 'PDM pinout: xdc and board_io.md section 8 agree' ($r.Code -eq 0) ''
} catch {
    Add-Result 'PDM pinout: xdc and board_io.md section 8 agree' $false $_.Exception.Message
}

# --------------------------------------- 26. mandatory acoustic/DAS/FIR acceptance
Write-Host '== 26. acoustic acceptance (DAS/FIR required, real AXI/RV32 RTL)' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'bash scripts/build_live_acoustic.sh && bash scripts/test_acoustic_acceptance.sh'
    Show-Output $r.Output
    Add-Result 'acoustic firmware: DAS/FIR and negative control' ($r.Code -eq 0 -and $r.Output -match 'ACOUSTIC_ACCEPTANCE_PASS') ''
} catch {
    Add-Result 'acoustic firmware: DAS/FIR and negative control' $false $_.Exception.Message
}

# ------------------------------------------- 27. whole-machine speedup (accelerated vs scalar)
# The end-to-end number for this project: one firmware round measured through the real PS
# program over real AXI on the real PS/PL RTL, with only FW_ACCEL changed between the two
# images. Replaces the 1.044x that used to be quoted as "end to end" -- that one divided by
# a single kernel, not by a chain. See README section 0.9 and docs/measurements.md section 13.
#   The script deletes build/whole_*.log first and refuses to summarise unless both sides
#   actually ran -- a stale log otherwise prints a perfectly good table for a build that
#   never happened. (Cost: two RTL runs, several minutes each. Skip with -SkipWholeMachine.)
Write-Host '== 27. whole-machine speedup (FW_ACCEL=1 vs 0)' -ForegroundColor Cyan
if ($SkipWholeMachine) {
    Add-Result 'whole-machine speedup' $true 'skipped by -SkipWholeMachine'
} else {
    try {
        $r = Invoke-Posix 'bash scripts/test_whole_machine.sh'
        Show-Output $r.Output
        Add-Result 'whole-machine speedup (accelerated vs all-scalar)' `
            ($r.Code -eq 0 -and $r.Output -match 'ACOUSTIC_RTL_PASS') ''
    } catch {
        Add-Result 'whole-machine speedup (accelerated vs all-scalar)' $false $_.Exception.Message
    }
}

# ------------------------------------------------- 28. PS-only baseline results match the PL firmware
# README section 34 needs PS-only vs PS+PL. The A9 cycle count needs the board, but the
# PRECONDITION does not: the PS-only program must compute the same results as the PL
# firmware, or the ratio compares two different jobs. Built here for the host and diffed
# bit-for-bit against the same goldens the PL side passes.
Write-Host '== 28. PS-only baseline (same source, same results)' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'gcc -O2 -w -DPSONLY_HOST -DFW_MEM_RELOCATE -DFW_RDCYCLE_OVERRIDE -DFW_ACCEL=0 -I sw -I sw/fw -o build/ps_only_host sw/ps_only.c sw/fw/fw_fft.c sw/fw/fw_gcc.c sw/fw/fw_srp.c sw/fw/fw_das.c sw/fw/fw_fir.c sw/fw/fw_scene.c sw/fw/fw_tables.c && python3 scripts/check_ps_only_results.py'
    Show-Output $r.Output
    Add-Result 'PS-only baseline matches the PL firmware bit-for-bit' `
        ($r.Code -eq 0 -and $r.Output -match 'PS_ONLY_MATCH') ''
} catch {
    Add-Result 'PS-only baseline matches the PL firmware bit-for-bit' $false $_.Exception.Message
}

# ------------------------------------------------- 29. PDM sampling-window timing budget
# SAMPLE_TICK is a REAL timing constraint for the IM73D122V01, not a free parameter: the
# microphone is high-Z for the half-period it does not own, so sampling the wrong half
# reads the OTHER microphone's bit (held by cable capacitance), not a shifted one. The
# old P-04 argument ("a wrong edge only adds a common delay, so it cancels in TDOA")
# assumed the mic drives the whole period, which this part does not.
# Item 20 cannot catch this by itself: its mic model never tri-states, which is exactly
# how that claim survived. pdm_decim.py section 8 derives the latch instant as
# (TICK+1)*25 ns, scans every candidate tick against the datasheet's t_DD/t_DV/t_HZ plus
# the board round-trip, and exits nonzero if the chosen tick misses the margin.
# Keep this item ASCII-only (check_ps_apps.py decodes these files as ASCII).
Write-Host '== 29. PDM sampling-window timing budget' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'python3 scripts/golden/pdm_decim.py'
    Show-Output $r.Output
    Add-Result 'PDM SAMPLE_TICK derived from datasheet timing (not guessed)' `
        ($r.Code -eq 0 -and $r.Output -match 'PASS:') ''
} catch {
    Add-Result 'PDM SAMPLE_TICK derived from datasheet timing (not guessed)' $false $_.Exception.Message
}

# --------------------------------------------------------------- 30. live DAS/FIR
Write-Host '== 30. continuous DAS and shared SIMD FIR' -ForegroundColor Cyan
try {
    $r = Invoke-Posix 'bash scripts/test_das_stream.sh'
    Show-Output $r.Output
    Add-Result 'live DAS/FIR: histories, core arbitration, overflow' ($r.Code -eq 0 -and $r.Output -match 'DAS_STREAM_PASS') ''
} catch {
    Add-Result 'live DAS/FIR' $false $_.Exception.Message
}

# --------------------------------------------------------------- summary
Write-Host ''
$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ('===== {0}/{1} checks passed =====' -f ($results.Count - $failed.Count), $results.Count) -ForegroundColor Cyan
if ($failed.Count -gt 0) {
    foreach ($f in $failed) {
        Write-Host ("  FAILED: {0}  {1}" -f $f.Name, $f.Detail) -ForegroundColor Red
    }
    exit 1
}
Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
exit 0
