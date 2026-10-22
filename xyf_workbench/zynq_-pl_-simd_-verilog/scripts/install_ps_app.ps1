<#
Copy the PS-side sources into a Vitis application's src/ directory.

Four apps, each a **separate Vitis application** (each with its own src/ and its own main):

    -App rv32   (default)  sw/ps_main.c + sw/acoustic_image.h
                Mandatory acoustic acceptance: download ITCM/DTCM, initialize GSC/steering,
                check FFT/GCC/DAS/GSC results and cycles. Build the generated image first
                with bash scripts/build_acoustic_acceptance.sh. No LED acceptance criteria.

    -App dualcore          sw/ps_dualcore.c
                Starts Cortex-A9 #1 from A9#0 (boot address + SEV) and proves it runs.
                Prerequisite for experiment 1 group B.

    -App fft               sw/ps_fft_test.c + all four frame_*.h vectors + the two shared headers
                The bearing envelope-spectrum pipeline on A9#1, checked term by term against
                MATLAB. Reads its input from a compiled-in vector.

    -App pdm               sw/ps_pdm.c
                The PDM capture window at AXI 0x300 (docs/pdm_array_spec.md P-11). Enables the
                chain, measures the sample rate, reads banks through INDEX+DATA, decodes the
                16-bit channel pairs and hands each bank back through ACK_SEQ/RELEASE. Needs no
                board peripheral and never touches the RV32 core. This is the PS half P-11 said
                was still to be written.

Every .c file here defines main(), so putting one into another's src/ gives two of them -- the
worst kind of link error to diagnose. Step 1 below scans for that first.

The shared headers go in the manifest for every app that includes them, not just the ones that
need them at link time: the app builds whatever is in its src/, and a missing header is a
compile error inside Vitis rather than a failure this script can see.

Why "copy" and not "import": a Vitis 2020.2 application project has no source manifest (unlike
old SDK, which registered files in .prj). The app builds whatever is in <app>/src/, so
"adding a source file" means putting the file in that directory.

Usage:
    .\scripts\install_ps_app.ps1 -AppSrc D:\Vitis\rv32_app\src
    .\scripts\install_ps_app.ps1 -AppSrc D:\Vitis\pdm_app\src -App pdm
    .\scripts\install_ps_app.ps1 -AppSrc D:\Vitis\rv32_app\src -ExpectBase 0x43C00000

Omitting -App means rv32, so existing call sites keep working.

-ExpectBase is optional: when given, RV32_BASE in the sources is checked against it. That
check exists because a mismatch between the app's RV32_BASE and the address the BD actually
assigned is the most common failure on this path, and the hardest to work backwards from
(readings come back all 0 or all F). The address is now pinned by
create_zynq_project.tcl (-target_address_space ... -offset); that script prints the actual
offset at the end of the build log and no longer reports [BD 5-669].

After copying, refresh the project in Vitis (select the app and press F5) before building.

NOTE: this file must stay **pure ASCII**. PowerShell 5.1 reads a .ps1 without a BOM using the
system ANSI code page (cp936 here), and a non-ASCII byte can pair with the following byte --
including a newline -- which corrupts the script itself. That is not theoretical: this file
used to carry Chinese comments and only parsed by luck of byte alignment. verify.ps1 and
run_iverilog.ps1 are ASCII throughout for the same reason; keep this one that way too.
#>
param(
    [Parameter(Mandatory = $true)][string]$AppSrc,
    [ValidateSet('rv32', 'dualcore', 'fft', 'pdm', 'ui')][string]$App = 'rv32',
    [string]$ExpectBase = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

# One fixed manifest per app. The list is written here rather than exposed as a -Files
# parameter on purpose: the value of this script is that the manifest matches the sources in
# git. Opening it up would make the SHA256 divergence check below meaningless (anyone could
# pass a list that does not match what is in Vitis and the script would still "pass").
$manifests = @{
    rv32     = @('sw\ps_main.c',  'sw\acoustic_image.h')
    dualcore = @('sw\ps_dualcore.c')
    # Both frames' vectors, because CASE_B selects between them at compile time
    # (ps_fft_test.c now wraps its #define in #ifndef so -DCASE_B=0 works from the command line).
    # ps_env_pipeline.h / ps_report.h are where the pipeline and the double formatter live since
    # the split -- without them this app does not compile at all.
    fft      = @('sw\ps_fft_test.c', 'sw\frame_b_input.h', 'sw\frame_b_expect.h',
                 'sw\frame_input.h', 'sw\frame_expect.h',
                 'sw\ps_env_pipeline.h', 'sw\ps_report.h')
    pdm      = @('sw\ps_pdm.c')
    # The browser view. Everything it includes has to be listed, because every manifest file is
    # copied into the app src/ and the app is built from there -- a header left out of this list
    # is a header that silently stays behind in sw/ and the Vitis build then fails on a missing
    # include. ps_diag.h is also where RV32_BASE lives for this app (the -ExpectBase check and
    # scripts/create_ps_apps.tcl both grep the manifest for that macro).
    # ps_ipc.h is the A9#1 <-> A9#0 shared page: ps_ui.c includes it from both cores (CPU1
    # runs the chain into it, CPU0 reads it back out). Leaving it off this list would break the
    # Vitis build on a missing include, the same way a missing ps_diag.h would.
    ui       = @('sw\ps_ui.c', 'sw\ps_ui_page.h', 'sw\ps_diag.h', 'sw\ps_ipc.h',
                 'sw\das_audio_contract.h', 'sw\ps_das_audio.h', 'sw\ps_das_mmio.h',
                 'sw\ps_das_report.h', 'sw\ps_das_replay.h', 'sw\ps_das_plots.h',
                 'sw\ps_das_fifo.h', 'sw\ps_pl_live.h', 'sw\ps_mic_levels.h', 'sw\ps_http_tx.h', 'sw\acoustic_live_image.h', 'sw\acoustic_debug4_image.h', 'sw\acoustic_live16_fixed_image.h', 'sw\acoustic_live16_image.h',
                 'sw\ps_features.h', 'sw\ps_classifier.h', 'sw\ps_output.h',
                 'sw\clf_model.h', 'sw\ps_env_pipeline.h')
}
$files = @($manifests[$App] | ForEach-Object { Join-Path $root $_ })

# ---- 0. The target has to look like a Vitis app src/ ----
if (-not (Test-Path -LiteralPath $AppSrc)) {
    throw "AppSrc not found: $AppSrc"
}
$markers = @('lscript.ld', 'Xilinx.spec')
$found = @($markers | Where-Object { Test-Path -LiteralPath (Join-Path $AppSrc $_) })
if ($found.Count -eq 0) {
    Write-Host "WARNING: $AppSrc has none of: $($markers -join ', ')" -ForegroundColor Yellow
    Write-Host "         That does not look like a Vitis application src/ folder." -ForegroundColor Yellow
    Write-Host "         Expect <workspace>\<app>\src" -ForegroundColor Yellow
} else {
    Write-Host "Target looks like a Vitis app src (found $($found -join ', '))"
}

# ---- 1. src/ must not already contain a different main() ----
$ours = @($files | ForEach-Object { Split-Path -Leaf $_ })
$foreign = @()
Get-ChildItem -LiteralPath $AppSrc -Filter '*.c' -File | ForEach-Object {
    if ($ours -notcontains $_.Name) {
        if (Select-String -LiteralPath $_.FullName -Pattern '\bmain\s*\(' -Quiet) {
            $foreign += $_.Name
        }
    }
}
if ($foreign.Count -gt 0) {
    throw ("$AppSrc already defines main() in: $($foreign -join ', '). " +
           "Each app has its own main(), so they must be separate Vitis applications.")
}

# ---- 2. The sources have to exist ----
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Source not found: $f" }
}

# Validate the requested address before copying any files into the app.
if ($ExpectBase -ne '') {
    if ($ExpectBase -notmatch '^0x[0-9A-Fa-f]{1,8}$') {
        throw 'ExpectBase must be a 32-bit hexadecimal address (for example 0x43C00000).'
    }
    $baseSource = @($files | ForEach-Object {
        Select-String -LiteralPath $_ -Encoding UTF8 -Pattern 'define\s+RV32_BASE\s+(0x[0-9A-Fa-f]+)'
    })
    if ($baseSource.Count -ne 1) { throw 'Expected exactly one RV32_BASE definition in the app sources.' }
    $sourceBase = $baseSource[0].Matches[0].Groups[1].Value
    if ([Convert]::ToUInt32($ExpectBase.Substring(2), 16) -ne [Convert]::ToUInt32($sourceBase.Substring(2), 16)) {
        throw "RV32_BASE mismatch: requested $ExpectBase, source has $sourceBase. No files copied."
    }
}

# ---- 3. Copy, but check both sides for divergence first ----
# Copy is a copy, not a link: sw/ and the Vitis src/ become two independent files from here.
# An edit made inside Vitis and then overwritten by a re-run of this script would be lost
# silently -- so compare hashes and stop for confirmation instead of merging quietly.
$diverged = @()
foreach ($f in $files) {
    $dest = Join-Path $AppSrc (Split-Path -Leaf $f)
    if (Test-Path -LiteralPath $dest) {
        $hSrc = (Get-FileHash -LiteralPath $f    -Algorithm SHA256).Hash
        $hDst = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($hSrc -ne $hDst) { $diverged += (Split-Path -Leaf $f) }
    }
}

if ($diverged.Count -gt 0 -and -not $Force) {
    Write-Host ''
    Write-Host "These files differ between sw\ and the app src:" -ForegroundColor Yellow
    foreach ($d in $diverged) { Write-Host "    $d" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host "sw\ is the version-controlled source of truth. If the difference is an edit" -ForegroundColor Yellow
    Write-Host "you made inside Vitis, move it back into sw\ first, then re-run this script." -ForegroundColor Yellow
    Write-Host "If sw\ really is the newer one, re-run with -Force to overwrite." -ForegroundColor Yellow
    throw 'Refusing to overwrite diverged files (use -Force if sw\ is the newer one).'
}

foreach ($f in $files) {
    $dest = Join-Path $AppSrc (Split-Path -Leaf $f)
    Copy-Item -LiteralPath $f -Destination $dest -Force
    Write-Host ("  copied {0} -> {1}" -f (Split-Path -Leaf $f), $dest)
}

# ---- 4. Check RV32_BASE ----
# ps_main.c and ps_pdm.c define the macro, so the file name is not hard-coded: find whichever
# file in this manifest defines it.
$withBase = $null
$base = $null
foreach ($f in $files) {
    $dest = Join-Path $AppSrc (Split-Path -Leaf $f)
    $m = Select-String -LiteralPath $dest -Encoding UTF8 -Pattern 'define\s+RV32_BASE\s+(0x[0-9A-Fa-f]+)' -ErrorAction SilentlyContinue
    if ($m) {
        $withBase = Split-Path -Leaf $f
        $base = $m.Matches[0].Groups[1].Value
        break
    }
}

if (-not $withBase) {
    # dualcore and fft never touch the AXI slave, so having no RV32_BASE is normal for them.
    # Only make noise about it when the caller asked for a check that cannot be performed.
    if ($ExpectBase -ne '') {
        Write-Host "WARNING: -ExpectBase was given but no 'define RV32_BASE' exists in the $App manifest" -ForegroundColor Yellow
    }
} else {
    Write-Host "RV32_BASE in $withBase = $base"
    if ($ExpectBase -ne '') {
        $want = $ExpectBase.ToLower() -replace '^0x', ''
        $got = $base.ToLower() -replace '^0x', ''
        $wantPad = $want.PadLeft(8, '0')
        $gotPad = $got.PadLeft(8, '0')
        if ($wantPad -eq $gotPad) {
            Write-Host "  [ok] matches the address you expect ($ExpectBase)" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] expected $ExpectBase but the source has $base" -ForegroundColor Red
            Write-Host "         Fix RV32_BASE (or better: override it from the compiler symbols)" -ForegroundColor Red
        }
    }
}

Write-Host ''
Write-Host 'Next steps in Vitis:'
Write-Host '  1. select the app project and press F5 (or right-click -> Refresh)'
Write-Host '  2. Project -> Build Project'
Write-Host '  3. Run As -> Launch Hardware (Single Application Debug)'
Write-Host '  4. Window -> Show View -> Terminal, baud 115200'
