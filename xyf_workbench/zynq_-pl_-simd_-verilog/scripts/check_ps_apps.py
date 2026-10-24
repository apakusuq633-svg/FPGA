#!/usr/bin/env python3
"""Stage 4: compile A9#0 sources against compile-only BSP headers.

Run from any directory with Python 3 and GCC on PATH. No stubbed application is
linked or executed. The full verification wrapper keeps this as item 14.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(command, *, expect_failure=False, source=None):
    result = subprocess.run(command, cwd=ROOT, input=source, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.stdout:
        print(result.stdout, end="", flush=True)
    if (result.returncode == 0) == expect_failure:
        raise RuntimeError("unexpected exit status %d: %s" %
                           (result.returncode, " ".join(command)))


def check_hardware_artifacts():
    """Cross-check the Vivado build product the PS-side sources depend on.

    RV32_BASE is an address the BD assigns, and nothing in the C sources can notice when the
    BD moves it -- a stale value only shows up as a dead board. So it is read out of the BD
    here and compared against every source that defines it.

    The BD lives under vivado_zynq/, which is gitignored (it is regenerable:
    create_zynq_project.tcl), so this checks only when it is present, and says so when it is
    not.
    """
    project_dir = Path(os.environ.get("ZYNQ_PROJ_DIR", "build/das12_zynq"))
    bd = ROOT / project_dir / "rv32_zynq.srcs/sources_1/bd/ps_pl/ps_pl.bd"
    if not bd.exists():
        print("PASS: no Vivado build products in the tree to cross-check", flush=True)
        return

    bd_text = bd.read_text(encoding="utf-8")

    # One AXI slave, one address: every source that defines RV32_BASE must agree with the BD.
    m = re.search(r'"address_block":\s*"/u_rv32_ps/s_axi/reg0"[^}]*'
                  r'"offset":\s*"(0x[0-9A-Fa-f]+)"', bd_text)
    if m:
        offset = int(m.group(1), 16)
        for src in ("sw/ps_main.c", "sw/ps_live.c", "sw/ps_dualcore.c", "sw/ps_fft_test.c", "sw/ps_pdm.c",
                    "sw/ps_diag.h"):
            mm = re.search(r"define\s+RV32_BASE\s+(0x[0-9A-Fa-f]+)",
                           (ROOT / src).read_text(encoding="utf-8"))
            if mm and int(mm.group(1), 16) != offset:
                raise RuntimeError("%s has RV32_BASE=%s but the BD assigned 0x%08X"
                                   % (src, mm.group(1), offset))
        print("PASS: RV32_BASE matches the BD-assigned slave offset 0x%08X" % offset,
              flush=True)

    # Station 15 (sw/ps_ui.c) reaches the network only if the BD actually put GEM0 on
    # MIO16-27. Same argument as RV32_BASE above: nothing in the C sources can notice when
    # it is off -- the symptom is a dead Ethernet port on the board and nothing else.
    #
    # It is especially easy to lose: ps7_config.tcl (generated, "do not hand-edit") has
    # ENET0 disabled, so enabling it is an override added afterwards in
    # scripts/create_zynq_project.tcl. Regenerating from a stale config silently drops it.
    def pcw(name):
        m = re.search(r'"%s":\s*\{\s*"value":\s*"([^"]*)"' % re.escape(name), bd_text)
        return m.group(1) if m else None

    if pcw("PCW_EN_ENET0") != "1":
        raise RuntimeError(
            "sw/ps_ui.c needs PS Ethernet but the BD has PCW_EN_ENET0=%r. The GEM0 "
            "override in scripts/create_zynq_project.tcl is missing or did not take; "
            "regenerate the BD and the bitstream." % pcw("PCW_EN_ENET0"))
    if pcw("PCW_ENET0_ENET0_IO") != "MIO 16 .. 27":
        raise RuntimeError("BD routes ENET0 to %r, expected 'MIO 16 .. 27'"
                           % pcw("PCW_ENET0_ENET0_IO"))
    print("PASS: BD has PS Ethernet (GEM0) on MIO16-27 -- station 15 can reach the network",
          flush=True)


def check_pdm_window():
    """Cross-check sw/ps_pdm.c's PDM window against rv32_pdm_capture.v.

    This window has already produced a real wrong diagnosis once: test_pdm_onboard.tcl walked
    with increasing addresses instead of writing INDEX and reading DATA, so it read ACKSEQ /
    RELEASE / FRAME / FROZEN / META and concluded "the words vary, there is signal". META
    happening to equal LEN (512) made it worse: 512 is also chan_align's DC residual bound, so
    the misreading looked confirmed (docs/issues/059).

    A host cannot run this path (the cstub headers return 0 rather than faking hardware), so the
    interface is checked statically: every register the program writes must be one the capture
    block acts on, and every one it reads must be one the block decodes. A write to an ignored
    address is a silent no-op; a read of an undecoded address returns 0 forever. Both look
    exactly like "the chain is dead" on the board.
    """
    src = ROOT / "sw/ps_pdm.c"
    rtl = ROOT / "rtl/array/rv32_pdm_capture.v"
    if not src.exists() or not rtl.exists():
        return

    text = src.read_text(encoding="utf-8")
    rtl_text = rtl.read_text(encoding="utf-8")

    # ps_pdm.c defines its offsets as R_X = PDM(n); read n back out of the #define lines.
    defined = {name: int(n) for name, n in
               re.findall(r"#define\s+(R_\w+)\s+PDM\((\d+)\)", text)}
    if len(defined) < 12:
        raise RuntimeError("only %d R_* = PDM(n) definitions found in sw/ps_pdm.c; the parse "
                           "has stopped seeing the register map" % len(defined))

    # Only what the code actually touches: the #define lines mention every register.
    body = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#define"))

    def touched(fn):
        names = set(re.findall(r"\b" + fn + r"\([^,()]*\+\s*(R_\w+)", body))
        for name in names:
            if name not in defined:
                raise RuntimeError("sw/ps_pdm.c uses %s, which is not defined as PDM(n)" % name)
        return {defined[n] for n in names}

    written = touched("Xil_Out32")
    read = touched("Xil_In32")

    # What the RTL acts on. Writes appear as `cfg_wr_i && cfg_addr_i == R_X` (and one
    # `R_GAIN0 + k`); reads are the case labels of the read mux.
    rtl_writes = set()
    for line in rtl_text.splitlines():
        if "cfg_wr_i" in line and "cfg_addr_i ==" in line:
            rtl_writes |= set(re.findall(r"cfg_addr_i\s*==\s*(R_\w+)", line))
    case_body = rtl_text.split("case (cfg_addr_i)", 1)[-1]
    rtl_reads = set(re.findall(r"^\s*(R_\w+)\s*:", case_body, re.M))
    rtl_reads |= {m for m in re.findall(r"cfg_addr_i\s*>=\s*(R_\w+)", case_body)}

    if not rtl_writes or not rtl_reads:
        raise RuntimeError("parsed no register decode out of rv32_pdm_capture.v -- the RTL "
                           "changed shape and this check is no longer looking at anything")

    names_by_num = {n: k for k, n in defined.items()}
    bad_w = sorted(names_by_num.get(n, hex(n)) for n in written - {defined[x]
                 for x in rtl_writes if x in defined})
    bad_r = sorted(names_by_num.get(n, hex(n)) for n in read - {defined[x]
                 for x in rtl_reads if x in defined})
    if bad_w or bad_r:
        raise RuntimeError(
            "sw/ps_pdm.c touches PDM registers the capture block ignores: writes %s, reads %s. "
            "A write there is a silent no-op and a read returns 0 forever -- both look like "
            "\"the chain never produced a frame\" on the board." % (bad_w, bad_r))

    # Floors, not exact counts: a helper taking a register as an argument is invisible to the
    # regexes, so a refactor could quietly shrink what this looks at. Moving a bank and handing
    # it back cannot be done with fewer registers than these.
    if len(written) < 5 or len(read) < 7:
        raise RuntimeError(
            "only %d writes / %d reads parsed out of sw/ps_pdm.c; the five-step bank read needs "
            "at least 5 and 7, so this check has stopped seeing its register accesses"
            % (len(written), len(read)))

    print("PASS: PDM window: %d register writes and %d reads all decoded by rv32_pdm_capture"
          % (len(written), len(read)), flush=True)


def main():
    compiler = shutil.which(os.environ.get("CC", "gcc"))
    if not compiler:
        raise RuntimeError("GCC missing: install gcc in the native shell or WSL")
    # Every .ps1 under scripts/, discovered rather than listed: the list used to name three of
    # them, and a fourth entry point (record_board_uart.ps1) appeared without being added -- a
    # hand-maintained list is exactly the thing this repo keeps getting bitten by. PS 5.1 reads a
    # BOM-less .ps1 with the system ANSI codepage, so one non-ASCII byte can pair with the next
    # byte -- including a newline -- and corrupt the script.
    ps1 = sorted((ROOT / "scripts").glob("*.ps1"))
    if not ps1:
        raise RuntimeError("no scripts/*.ps1 found -- has the layout changed?")
    for path in ps1:
        try:
            path.read_bytes().decode("ascii")
        except UnicodeDecodeError as exc:
            raise RuntimeError(
                "%s is not ASCII (%s). PowerShell 5.1 would decode it with the system codepage "
                "and can glue two lines together; see the note at the top of scripts/verify.ps1."
                % (path.name, exc)) from exc
    print("PASS: PowerShell entry scripts are ASCII (%d files)" % len(ps1), flush=True)

    check_hardware_artifacts()
    check_pdm_window()

    # -Wno-pointer-to-int-cast: the host is 64-bit, the target is 32-bit ARM. Handing a
    # function pointer to Xil_Out32 as u32 (how CPU1's entry address is set) is correct on
    # the target and warned about on the host. -m32 would model it properly but needs
    # gcc-multilib; this is the narrowest suppression that still keeps every other warning.
    flags = [compiler, "-std=c11", "-fsyntax-only", "-Wall", "-Wextra", "-Werror",
             "-Wformat=2", "-Wno-pointer-to-int-cast", "-Dmain=app_main", "-Isw/cstub", "-Isw"]
    variants = [
        ("DAS mono block receiver and diagnostic commissioning app", "sw/ps_das_diag.c", []),
        ("DAS commissioning app with matching PL window enabled", "sw/ps_das_diag.c",
         ["-DPS_DAS_WINDOW_PRESENT=1"]),
        ("acoustic acceptance (FFT/GCC/DAS + SIMD FIR)", "sw/ps_main.c", []),
        ("live PDM/DAS/SIMD FIR", "sw/ps_live.c", []),
        # The two programs that used to sit outside every build and every check. They were
        # 2400+ lines with zero coverage: a typo in them could only ever be found on the board.
        ("dualcore (CPU1 bring-up)", "sw/ps_dualcore.c", []),
        ("bearing pipeline frame B", "sw/ps_fft_test.c", ["-DCASE_B=1"]),
        ("bearing pipeline frame A", "sw/ps_fft_test.c", ["-DCASE_B=0"]),
        # The PDM capture program consumes the PDM window at 0x300. It needs the board to mean
        # anything, so a host compile is the only coverage it gets in CI.
        ("PDM capture window (12 ch)", "sw/ps_pdm.c", []),
        # Station 12's inference kernel over the exported random forest. It touches no
        # registers at all -- it compares the built-in samples against MATLAB's answers --
        # so a host compile plus -Werror is the whole coverage it can get off-board.
        ("classifier inference (station 12)", "sw/ps_clf_test.c", []),
        # Stations 11 (features) and 13 (output) are header-only, so this app is the only thing
        # that instantiates them: it is where they get compiled at all. Like the classifier test
        # it needs no register the stub would have to fake -- it builds its own synthetic frame --
        # so a host compile plus -Werror is again the whole coverage available off-board.
        ("diagnosis chain 11 -> 12 -> 13", "sw/ps_diag_test.c", []),
        # Station 15 (the browser view). Its two halves split by what the cstub can stand in
        # for: ps_ui_page.h is pure string formatting, so it compiles here; ps_ui.c is the lwIP
        # server, and sw/cstub has no lwIP headers, so nothing off-board can compile it -- that
        # one is board-only, like scripts/*.tcl. This app is therefore the entire host coverage
        # of the page, which is why it checks the JSON byte for byte rather than field by field:
        # a dropped comma or a reordered field shows up in a browser as a blank page, and
        # nothing in the serial log.
        ("browser view (station 15)", "sw/ps_ui_test.c", []),
        # The cross-core page between A9#1 (stations 11->13, sw/ps_ui.c's cpu1_main) and A9#0
        # (the HTTP server in the same file). Both of its users are board-only -- the two cores
        # cannot be run here -- and a broken handshake shows up as an occasional wrong frame or
        # a page stuck on "waiting", neither of which points back at the handshake. ps_ipc.h
        # touches no register and no lwIP header, so unlike ps_ui.c it does compile here, and
        # this test is the only place the seq/seq handshake is exercised at all.
        ("cross-core page (A9#1 -> A9#0)", "sw/ps_ipc_test.c", []),
        # README section 34's PS-only half. It is not a second implementation: ps_only.c
        # pulls in sw/fw/fw_main.c verbatim, so a host syntax check here also covers that
        # case. The three overrides are what make the firmware source compile off-RISC-V;
        # without them the .insn asm never assembles (or worse, the relocated memory map
        # silently keeps pointing at DTCM).
        # -Wno-int-to-pointer-cast: the firmware addresses the memory map as uint32_t
        # everywhere by design (it runs on a 32-bit core). On a 64-bit host the
        # relocation macro therefore trips the cast warning on every access. The same
        # suppression already exists above for the opposite direction.
        ("PS-only baseline (firmware source on Cortex-A9)",
         "sw/ps_only.c",
         ["-DFW_ACCEL=0", "-DFW_MEM_RELOCATE", "-DFW_RDCYCLE_OVERRIDE",
          "-DFW_MAIN_RETURNS=1", "-Wno-int-to-pointer-cast", "-Isw/fw"]),
    ]
    for label, source, defines in variants:
        run(flags + defines + [source])
        print("PASS: " + label, flush=True)

    # Execute the protocol/segment tests, not just syntax-check them.
    das_test = ROOT / "build" / ("ps_das_audio_test.exe" if os.name == "nt" else "ps_das_audio_test")
    das_test.parent.mkdir(exist_ok=True)
    run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Isw",
         "sw/ps_das_audio_test.c", "-o", str(das_test)])
    run([str(das_test)])
    fifo_test = ROOT / "build" / ("ps_das_fifo_test.exe" if os.name == "nt" else "ps_das_fifo_test")
    run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Isw",
         "sw/ps_das_fifo_test.c", "-o", str(fifo_test)])
    run([str(fifo_test)])
    for label,defines in [('default12',[]),('fixed16',['-DUI_DAS_ACTIVE_CHANNELS=16','-DUI_LIVE16_LOCALIZATION=0']),
                          ('default16',['-DUI_DAS_ACTIVE_CHANNELS=16']),
                          ('located16',['-DUI_DAS_ACTIVE_CHANNELS=16','-DUI_LIVE16_LOCALIZATION=1'])]:
        executable=ROOT/'build'/('ps_fifo_'+label+('.exe' if os.name=='nt' else ''))
        run([compiler,'-std=c11','-O2','-Wall','-Wextra','-Werror','-Isw',*defines,
             'sw/ps_das_fifo_test.c','-o',str(executable)])
        run([str(executable)])
    for source in ('ps_display_test','ps_mic_levels_test','ps_http_tx_test','ps_location_scale_test','fw_location_quality_test','circular9_deadline_test'):
        executable=ROOT/'build'/(source+('.exe' if os.name=='nt' else ''))
        run([compiler,'-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-function','-Isw/cstub','-Isw',
             'sw/'+source+'.c','-o',str(executable),'-lm'])
        run([str(executable)])
    pipeline_test = ROOT / "build" / ("ps_das_pipeline_test.exe" if os.name == "nt" else "ps_das_pipeline_test")
    run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function",
         "-Isw/cstub", "-Isw", "sw/ps_das_pipeline_test.c", "-o", str(pipeline_test), "-lm"])
    run([str(pipeline_test)])
    concurrency_test = ROOT / "build" / ("ps_das_concurrency_test.exe" if os.name == "nt" else "ps_das_concurrency_test")
    run([compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread", "-Isw",
         "sw/ps_das_concurrency_test.c", "-o", str(concurrency_test)])
    run([str(concurrency_test)])

    # A broken printf declaration must not silently turn -Wformat into a no-op.
    run(flags + ["-x", "c", "-"], expect_failure=True,
        source='#include "xil_printf.h"\nvoid probe(void) { xil_printf("%u", "bad"); }\n')
    print("PASS: format mismatch is rejected (expected diagnostic above)", flush=True)
    print("PASS: A9#0 compile checks; no BSP link or board execution", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, UnicodeError, RuntimeError) as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
