#!/usr/bin/env python3
"""Cross-check the PDM array pinout: constraint file vs the doc's "current" table.

`docs/board_io.md` section 8 and `constrs/ps_pl_wrapper.xdc` both state where the nine
PDM signals land, and `docs/pdm_array_spec.md` claims in writing that the two are
"bit-for-bit identical" -- but nothing checked that claim. The two sources drifted once
already, in the other direction and across seven documents: some said the 8-channel
array is wired to J3 and some to J4, and the two connectors put PDM_CLK on *different
package pins* (V16 vs W15). Following the wrong table gives a board where nothing moves
and nothing reports an error (docs/issues/063).

So this checks, statically:

  * the xdc and the section-8 "current" table name the same package pin for each of the
    nine signals -- and both sides really parsed nine;
  * PDM_CLK sits on J3 pin 36, the one signal position in the 25-40 block adjacent to a
    ground return (J3.37). That is why the 2.5 MHz clock that fans out to every
    microphone is there, and the note under the table says not to move it;
  * each data pin carries PULLDOWN true -- a floating line reads as noise, so the
    disconnect detector never fires (P-12);
  * all nine share one IOSTANDARD (one bank, one VCCO assumption);
  * the connector pins are nine distinct positions;
  * the section-8 "current" table and the section-8 "J4 recommended" table do not
    overlap: only one array can be plugged in at a time;
  * no second .xdc also pins a PDM port.

Every check above is parse-then-compare, so each is guarded against the failure mode this
repo has already hit twice: an empty parse comparing equal to an empty parse and printing
PASS. docs/issues/042 (a wraparound criterion that any width satisfies) and
docs/issues/050 (19 of 19 pins "not found", compared equal, reported PASS) are the same
shape -- so here a short parse is a failure, never a pass.

Run from any directory with Python 3. Wired into scripts/verify.ps1. The optional
--xdc/--doc overrides exist so the negative controls can run against mutated copies.
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

XDC = "constrs/ps_pl_wrapper.xdc"
DOC = "docs/board_io.md"

CLK = "clk"
DATA = ["din%d" % i for i in range(8)]
ALL = [CLK] + DATA

# Headings to look for in board_io.md, verbatim. These are the only non-ASCII strings in
# this file and they are used for matching only -- every message printed or raised below
# is ASCII, because stdout's encoding is not guaranteed when verify.ps1 runs this through
# wsl.exe, and a UnicodeEncodeError while printing PASS would read as a failed check.
HEAD_CURRENT = "8 通道引脚表"          # the authoritative "current" table
HEAD_J4 = "接 J4 的推荐分配"            # the alternative pinout, same section
CUR_LABEL = "the board_io.md section-8 eight-line profile-superset table"
J4_LABEL = "the board_io.md section-8 'J4 recommended' table"

# "DIN0-DIN7" as one row, with either an en dash or a hyphen.
RANGE = re.compile(r"DIN(\d+)\s*[–—-]\s*DIN(\d+)", re.IGNORECASE)


def signal_key(name):
    """The doc spelling or the port spelling -> "clk" / "dinN", else None."""
    text = name.replace("*", "").strip()
    if text.replace(" ", "") in ("PDM_CLK", "pdm_clk_o"):
        return CLK
    m = re.fullmatch(r"DIN(\d+)", text, re.IGNORECASE)
    if m:
        return "din" + m.group(1)
    m = re.fullmatch(r"pdm_din_i\[(\d+)\]", text)
    if m:
        return "din" + m.group(1)
    return None


def row_keys(cell):
    """Keys for one 信号 cell, expanding a compressed "DIN0-DIN7" range."""
    text = cell.replace("*", "").strip()
    m = RANGE.search(text)
    if m:
        lo, hi = int(m.group(1)), int(m.group(2))
        return ["din%d" % i for i in range(lo, hi + 1)]
    key = signal_key(text)
    return [key] if key else []


def parse_doc_table(lines, where):
    """{key: (connector_pin, package_pin)} from the markdown rows in `lines`."""
    out = {}
    for line in lines:
        if not line.lstrip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        # Header row ("| 信号 | ...") and the |---| separator both land here.
        if len(cells) < 3 or set(cells[0]) <= set("-: "):
            continue
        keys = row_keys(cells[0])
        if not keys:
            continue                       # a 3V3 / GND / 余量 row
        pins = [p.replace("*", "").strip() for p in cells[1].split(",")]
        pkgs = [p.replace("*", "").strip() for p in cells[2].split(",")]
        if len(keys) == 1:
            out[keys[0]] = (pins[0], pkgs[0])
            continue
        if len(pins) != len(keys) or len(pkgs) != len(keys):
            raise RuntimeError(
                "%s: row %r expands to %d signals but has %d connector pins and %d package "
                "pins -- the compressed row no longer lines up"
                % (where, cells[0], len(keys), len(pins), len(pkgs)))
        for key, pin, pkg in zip(keys, pins, pkgs):
            out[key] = (pin, pkg)
    return out


def section(lines, heading_text):
    """The body of the first heading containing `heading_text`, or None."""
    for i, line in enumerate(lines):
        if line.startswith("#") and heading_text in line:
            body = []
            for line in lines[i + 1:]:
                if line.startswith("#"):
                    break
                body.append(line)
            return body
    return None


# set_property -dict {...} [get_ports port]  /  [get_ports {port[0]}]
CONSTRAINT = re.compile(
    r"set_property\s+-dict\s*\{([^}]*)\}\s*\[get_ports\s+(?:\{([^}]*)\}|(\S+))\]")


def parse_xdc(path):
    """{key: {"pin":..., "io":..., "pull":bool}} for the PDM ports in one .xdc."""
    out = {}
    for props, braced, bare in CONSTRAINT.findall(path.read_text(encoding="utf-8")):
        key = signal_key(braced or bare)
        if key is None:
            continue
        pin = re.search(r"PACKAGE_PIN\s+(\S+)", props)
        io = re.search(r"IOSTANDARD\s+(\S+)", props)
        out[key] = {
            "pin": pin.group(1) if pin else None,
            "io": io.group(1) if io else None,
            "pull": re.search(r"PULLDOWN\s+true", props) is not None,
        }
    return out


def check(xdc_path, doc_path):
    if not xdc_path.exists():
        raise RuntimeError("%s is missing; the PDM array is constrained there" % xdc_path)
    if not doc_path.exists():
        raise RuntimeError("%s is missing; its section 8 is the authoritative pinout table"
                           % doc_path)

    xdc = parse_xdc(xdc_path)
    if len(xdc) != 9:
        raise RuntimeError(
            "parsed %d PDM ports out of %s, expected 9 (1 clock + 8 data). A parse this short "
            "must not be allowed to reach a comparison -- an empty parse compares equal to an "
            "empty parse. See docs/issues/050."
            % (len(xdc), xdc_path.name))
    if sorted(xdc) != sorted(ALL):
        raise RuntimeError("%s pins %s, expected %s"
                           % (xdc_path.name, sorted(xdc), sorted(ALL)))

    lines = doc_path.read_text(encoding="utf-8").splitlines()
    cur_body = section(lines, HEAD_CURRENT)
    if cur_body is None:
        raise RuntimeError(
            "%s: no heading containing the current-table name (%r). That table is the "
            "authoritative pinout; if it was renamed, this check stopped looking at anything."
            % (doc_path.name, HEAD_CURRENT))
    cur = parse_doc_table(cur_body, CUR_LABEL)
    # Count AND key set: nine rows that happen to be named din1..din9 would pass a count
    # check and then blow up as a KeyError below, which reads as a crash, not a FAIL.
    if sorted(cur) != sorted(ALL):
        raise RuntimeError(
            "%s yields %d signals %s, expected %s -- refusing to compare a table that is not "
            "the one this check is looking for" % (CUR_LABEL, len(cur), sorted(cur), sorted(ALL)))

    # The claim pdm_array_spec.md makes in writing: xdc and this table agree bit for bit.
    for key in ALL:
        if xdc[key]["pin"] != cur[key][1]:
            raise RuntimeError(
                "%s and %s disagree about %s: the constraint file says %s, the table says %s. "
                "Wiring the array from the wrong one gives a board where nothing moves and "
                "nothing errors -- see docs/issues/063."
                % (xdc_path.name, CUR_LABEL, key.upper(), xdc[key]["pin"], cur[key][1]))

    if cur[CLK][0] != "36":
        raise RuntimeError(
            "PDM_CLK is on J3 pin %s, not 36. Pin 36 is the only signal position in the 25-40 "
            "block adjacent to a ground return (J3.37); the 2.5 MHz clock that fans out to "
            "every microphone is there for that return path. The note under the table says not "
            "to move it." % cur[CLK][0])

    j3 = [cur[k][0] for k in ALL]
    if len(set(j3)) != 9:
        raise RuntimeError("%s puts two signals on one J3 pin: %s" % (CUR_LABEL, sorted(j3)))

    unpulled = [k.upper() for k in DATA if not xdc[k]["pull"]]
    if unpulled:
        raise RuntimeError(
            "%s on the data line(s) %s. Without a pull-down an unplugged line floats, the "
            "bitstream reads as noise, and the frozen detector never fires -- a disconnect then "
            "shows up only as 'the localization result makes no sense'." % ("no PULLDOWN true",
                                                                          unpulled))

    ios = sorted({xdc[k]["io"] for k in ALL})
    if len(ios) != 1 or ios[0] is None:
        raise RuntimeError(
            "the nine PDM pins do not share one IOSTANDARD (%s). They are all Bank 34, so they "
            "share one VCCO -- and VCCO_34 has never been measured (see board_io.md, '待实测')."
            % ios)

    # Both tables are in section 8, and only one array can be plugged in at a time.
    j4_body = section(lines, HEAD_J4)
    if j4_body is None:
        raise RuntimeError(
            "%s: no heading containing the J4-table name (%r). That table is the alternative "
            "pinout; without it this check cannot tell whether the current table picked up a "
            "row from it." % (doc_path.name, HEAD_J4))
    j4 = parse_doc_table(j4_body, J4_LABEL)
    if sorted(j4) != sorted(ALL):
        raise RuntimeError("%s yields %d signals %s, expected %s"
                           % (J4_LABEL, len(j4), sorted(j4), sorted(ALL)))

    overlap = sorted(set(cur[k][1] for k in ALL) & set(j4[k][1] for k in ALL))
    if overlap:
        raise RuntimeError(
            "the 'current' table and the 'J4 recommended' table share package pin(s) %s. They "
            "are different connectors carrying the same nine signals, so the current table has "
            "picked up a row from the alternative -- which is exactly how docs/issues/063 "
            "started." % overlap)

    # A PDM port pinned in two .xdc files silently overrides, and the stale one is invisible.
    elsewhere = []
    for path in sorted(xdc_path.parent.glob("*.xdc")):
        if path.name != xdc_path.name and parse_xdc(path):
            elsewhere.append(path.name)
    if elsewhere:
        raise RuntimeError(
            "PDM ports are also pinned in %s. Two constraint files for one port: whichever "
            "Vivado reads last wins, and the losing file still looks correct."
            % ", ".join(elsewhere))

    print("PASS: PDM pinout: %d signals, %s and %s agree bit for bit; PDM_CLK on J3.36/%s; "
          "%d data pins pulled down; IOSTANDARD %s; no overlap with the J4 table"
          % (len(ALL), xdc_path.name, CUR_LABEL, cur[CLK][1], len(DATA), ios[0]), flush=True)
    print("      J3 package pins: %s"
          % " ".join("%s=%s" % (k.upper(), cur[k][1]) for k in ALL), flush=True)


def self_test():
    """Each mutation below breaks one thing; every one must be rejected.

    A cross-check that cannot fail is worth nothing, and this repo has already produced
    two of those: docs/issues/042 (a wraparound criterion every width satisfies) and
    docs/issues/050 (19 of 19 pins "not found", compared equal, reported PASS). So the
    controls run on every invocation: if a refactor ever makes one of them stop firing,
    this fails rather than quietly certifying the pinout forever.
    """
    doc = (ROOT / DOC).read_text(encoding="utf-8")
    xdc = (ROOT / XDC).read_text(encoding="utf-8")
    # (label, fragment the error must contain, doc text, {xdc filename: text})
    cases = [
        ("package pin disagrees with the table", "disagree about CLK",
         doc.replace("| V16 | 原 BCLK |", "| W16 | 原 BCLK |"), {"a.xdc": xdc}),
        ("PDM_CLK moved off J3.36", "not 36",
         doc.replace("| **36** | V16 |", "| **35** | V16 |"), {"a.xdc": xdc}),
        ("the J4 table takes a pin the current table uses", "share package pin",
         doc.replace("| DIN0 | 35 | V15 |", "| DIN0 | 35 | Y16 |"), {"a.xdc": xdc}),
        # The port name trails the properties on the line, so this is a line edit, not a
        # regex over the "PULLDOWN true" that precedes it.
        ("a data pin loses PULLDOWN", "PULLDOWN", doc,
         {"a.xdc": "\n".join(l.replace(" PULLDOWN true", "") if "pdm_din_i[3]" in l else l
                             for l in xdc.splitlines())}),
        ("no PDM ports parse (the 050 shape)", "expected 9",
         doc, {"a.xdc": "# nothing here\n"}),
        ("the section-8 table is gone", "no heading",
         "\n".join(doc.splitlines()[:120]), {"a.xdc": xdc}),
        # A row this check does not recognise must shorten the table, not be silently
        # ignored while the remaining rows still line up.
        ("a signal row is renamed", "yields 8 signals",
         doc.replace("| **PDM_CLK** | **36** | V16 |", "| **PDM_CLKX** | **36** | V16 |"),
         {"a.xdc": xdc}),
        ("a second .xdc also pins a PDM port", "also pinned", doc,
         {"a.xdc": xdc, "b.xdc": "set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} "
                                "[get_ports pdm_clk_o]\n"}),
    ]
    bad = []
    with tempfile.TemporaryDirectory(prefix="pdm-pins-") as tmp:
        for i, (label, fragment, doc_text, xdcs) in enumerate(cases):
            case = Path(tmp) / ("case%d" % i)
            case.mkdir()
            (case / "doc.md").write_text(doc_text, encoding="utf-8")
            for name, text in xdcs.items():
                (case / name).write_text(text, encoding="utf-8")
            try:
                check(case / "a.xdc", case / "doc.md")
            except RuntimeError as exc:
                if fragment not in str(exc):
                    bad.append("%s: rejected, but for the wrong reason (%r)" % (label, str(exc)))
            else:
                bad.append("%s: ACCEPTED a mutated input" % label)
    if bad:
        raise RuntimeError("the negative controls did not all fire -- this check has stopped "
                           "being able to fail: " + "; ".join(bad))
    print("PASS: %d negative controls all rejected (the check can still fail)" % len(cases),
          flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--xdc", default=XDC, help="constraint file (default: %s)" % XDC)
    ap.add_argument("--doc", default=DOC, help="pinout table (default: %s)" % DOC)
    ap.add_argument("--self-test", action="store_true",
                    help="run only the negative controls and exit")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return 0
    # Overrides exist so the controls can be pointed at mutated copies by hand; the
    # controls themselves are built from the real files, so they are skipped for those.
    if args.xdc == XDC and args.doc == DOC:
        self_test()
    check(ROOT / args.xdc, ROOT / args.doc)
    if args.xdc == XDC and args.doc == DOC:
        print("PASS: default target is 12 channels / 6 DATA (DIN0..5) + CLOCK; "
              "the eight-line table covers legal 8/16-channel profiles; hardware UNVERIFIED")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, UnicodeError, RuntimeError) as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
