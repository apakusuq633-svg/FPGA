# Refuse to touch the board while the OTHER project is using its JTAG.
#
#   .\scripts\check_jtag_owner.ps1            # exit 0 = clear, 1 = someone else has it
#   .\scripts\check_jtag_owner.ps1 -Throw     # throw instead, for callers
#
# WHY THIS EXISTS (measured 2026-10-04)
#   This machine also holds a second project:
#       D:\Users\xyfhhh\Desktop\multichannel_acoustic\zynq_-pl_-simd_-verilog   (the I2S build)
#   Its XSCT scripts connect to the SAME board at arbitrary times.
#
#   The failure mode is very easy to misread. The second XSCT finds an hw_server already
#   listening on TCP:3121 (started by whoever got there first) and REUSES it, so two XSCT
#   sessions drive one JTAG adapter. What you see is:
#       Cannot reset DAP. AP transaction error, DAP status 0x30000021
#       no targets found with "name =~ "APU""
#       `targets` hanging and never returning
#   -- which looks exactly like a dead board. It is not. Someone is competing for it.
#
#   Checking `Get-Process` "just before running" is NOT enough: the other side's scripts are
#   short-lived and start at random moments, so a clean check does not mean a clean next
#   second. This script gives an explicit criterion (which PID, which command line); board
#   scripts should call it before `connect`, and again right before the run proper. Only
#   scheduling between the two teams removes the contention; software can only stop us from
#   misdiagnosing it.
#
# NOTE: keep this file ASCII-only. PowerShell 5.1 reads a BOM-less .ps1 with the system ANSI
# codepage, so any non-ASCII byte corrupts the parse (check_ps_apps.py enforces this).

param(
    [switch]$Throw
)

$ErrorActionPreference = 'Stop'

# The criterion is the COMMAND LINE, not the process name: both sides run rdi_xsct.exe and
# hw_server.exe, so names are identical and useless for telling them apart.
$OTHER = 'multichannel_acoustic'
$MINE  = 'Desktop\PDM\zynq_-pl_-simd_-verilog'

$procs = @(Get-CimInstance Win32_Process `
             -Filter "Name like '%xsct%' or Name like '%vivado%' or Name like '%hw_server%' or Name like '%vitis%'" `
             -ErrorAction SilentlyContinue)

$mine  = @($procs | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$MINE*" })
$other = @($procs | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$OTHER*" })

if ($other.Count -gt 0) {
    $names = ($other | ForEach-Object { "PID $($_.ProcessId) $($_.Name)" }) -join '; '
    $msg = "The OTHER project is using this board's JTAG: $names" + [Environment]::NewLine +
           "  cmdline: $($other[0].CommandLine)" + [Environment]::NewLine + [Environment]::NewLine +
           "Two XSCT sessions reuse one hw_server and corrupt each other's DAP access. The" + [Environment]::NewLine +
           "symptoms are 'Cannot reset DAP ... 0x30000021', a hanging 'targets', and" + [Environment]::NewLine +
           "'no targets found with APU' -- none of which means the board is broken." + [Environment]::NewLine +
           "Wait for the other side to finish, or agree on time slots, before touching the board."
    Write-Host $msg -ForegroundColor Yellow
    if ($Throw) { throw $msg }
    exit 1
}

Write-Host 'JTAG ownership check passed: no other project is using the board.' -ForegroundColor Green
if ($mine.Count -gt 0) {
    Write-Host ("  our own processes: " + (($mine | ForEach-Object { "PID $($_.ProcessId) $($_.Name)" }) -join ', '))
}
exit 0
