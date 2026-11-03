#!/usr/bin/env python3
"""Check that what is about to be downloaded is what is in the repository.

Run this before the first JTAG session, and again after any rebuild. It answers one
question: *do the ELF in Vitis, the sources in Vitis, the bitstream, the XSA and the RTL in
this repository all belong to the same build?* Every failure mode covered here has happened
at least once in this project -- a stale XSA whose BSP silently lacked the iicps driver, a
source edited in the repository but never copied into the app, a bitstream exported before
the last RTL edit.

It never touches hardware: no JTAG, no board. The electrical and acoustic acceptance in
README_BOARD.md section 6 still needs the real rig.

Every problem is reported, not just the first one: a gate that stops at the first missing
file hides the other four things also missing, and this one is meant to be read as a
checklist. Exit code 0 only when everything agrees.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def manifest_apps():
    """{manifest key: Vitis app name}, read out of install_ps_app.ps1.

    Derived rather than listed: the app set has grown from two to six, and a second
    hand-maintained copy of it here would be one more list to forget. The app name is the
    manifest key plus '_app', which is the naming create_ps_apps.tcl already uses.
    """
    text = (ROOT / 'scripts/install_ps_app.ps1').read_text(encoding='ascii')
    keys = re.findall(r'^\s*(\w+)\s*=\s*@\(', text, re.M)
    if not keys:
        raise RuntimeError('no app manifests found in scripts/install_ps_app.ps1')
    return {key: key + '_app' for key in keys}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=Path('D:/Vitis'),
                        help='Vitis workspace holding the platform and the app projects')
    args = parser.parse_args()

    bit = ROOT / 'vivado_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit'
    xsa = ROOT / 'vivado_zynq/ps_pl_wrapper.xsa'
    problems = []
    evidence = {'apps': {}}

    # ---- 1. the implementation bitstream, and the copy embedded in the XSA ----
    bit_hash = None
    if not bit.exists():
        problems.append('no implementation bitstream at %s -- build it first: '
                        'vivado -mode batch -source scripts/export_xsa.tcl' % bit)
    else:
        bit_hash = sha256(bit.read_bytes())
        evidence['bit_sha256'] = bit_hash

    if not xsa.exists():
        problems.append('no XSA at %s -- Vitis has nothing to build the platform from' % xsa)
    elif bit_hash is None:
        pass                      # the bitstream problem is already reported
    else:
        try:
            with zipfile.ZipFile(xsa) as archive:
                embedded = [n for n in archive.namelist() if n.endswith('.bit')]
                if len(embedded) != 1:
                    problems.append('XSA contains %d bitstreams, expected exactly 1'
                                    % len(embedded))
                elif sha256(archive.read(embedded[0])) != bit_hash:
                    problems.append('the XSA does not contain the current implementation '
                                    'bitstream -- re-export it (scripts/export_xsa.tcl)')
                else:
                    evidence['xsa_sha256'] = sha256(xsa.read_bytes())
        except zipfile.BadZipFile:
            problems.append('the XSA is not a readable archive: %s' % xsa)

    # ---- 2. the bitstream the Vitis platform will actually load ----
    if bit_hash is not None:
        platform_bit = args.workspace / 'PS-PL/hw/ps_pl_wrapper.bit'
        if not platform_bit.exists():
            problems.append('the Vitis platform has no bitstream at %s -- regenerate the '
                            'platform: xsct scripts/create_ps_apps.tcl' % platform_bit)
        elif sha256(platform_bit.read_bytes()) != bit_hash:
            problems.append('the Vitis platform still uses a different bitstream; '
                            'regenerate the platform: xsct scripts/create_ps_apps.tcl')

    # ---- 3. RTL newer than the bitstream ----
    # Any edit under rtl/ or to the XDC may or may not change the netlist, and this cannot tell
    # the two apart -- so it errs toward rebuilding. That is deliberate: the failure it guards
    # against (downloading a bitstream that predates the RTL) is invisible on the board.
    if bit.exists():
        for src in (list((ROOT / 'rtl').rglob('*.v')) + list((ROOT / 'rtl').rglob('*.vh')) +
                    [ROOT / 'constrs/ps_pl_wrapper.xdc']):
            if src.stat().st_mtime > bit.stat().st_mtime:
                problems.append('%s is newer than the bitstream -- rebuild it (scripts/'
                                'export_xsa.tcl), or the board runs older logic'
                                % src.relative_to(ROOT))

    # ---- 4. every app: sources copied, sources unchanged, ELF newer than them ----
    for key, app in sorted(manifest_apps().items()):
        manifest = (ROOT / 'scripts/install_ps_app.ps1').read_text(encoding='ascii')
        match = re.search(r'^\s*' + key + r'\s*=\s*@\((.*?)\)', manifest, re.M | re.S)
        if not match:
            problems.append('no manifest for app %s in install_ps_app.ps1' % key)
            continue
        sources = re.findall(r"'(sw\\[^']+)'", match.group(1))
        if not sources:
            problems.append('app %s has an empty source manifest' % key)

        elf = args.workspace / app / 'Debug' / (app + '.elf')
        if not elf.exists():
            problems.append('no ELF for %s at %s -- build it: xsct scripts/create_ps_apps.tcl'
                            % (app, elf))
            continue
        evidence['apps'][app] = {'elf': str(elf.resolve()), 'sha256': sha256(elf.read_bytes())}

        for name in sources:
            source = ROOT / name.replace('\\', '/')
            installed = args.workspace / app / 'src' / source.name
            if not installed.exists():
                problems.append('%s: %s was never copied into the app' % (app, source.name))
                continue
            # Vitis may normalize newlines; compare source text, not newline bytes.
            if source.read_text(encoding='utf-8') != installed.read_text(encoding='utf-8'):
                problems.append('%s: installed %s differs from the repository copy'
                                % (app, source.name))
            if installed.stat().st_mtime > elf.stat().st_mtime:
                problems.append('%s: the ELF predates %s -- rebuild the app'
                                % (app, source.name))

    evidence['ok'] = not problems
    evidence['problems'] = problems
    report = ROOT / 'build/board_ready.json'
    report.parent.mkdir(exist_ok=True)
    report.write_text(json.dumps(evidence, indent=2), encoding='utf-8')

    if problems:
        print('FAIL: %d problem(s) -- do not start a JTAG session on this tree' % len(problems))
        for problem in problems:
            print('  - %s' % problem)
        print('report: %s' % report)
        return 1
    print('PASS: XSA, implementation, Vitis platform, %d source sets and %d ELFs agree'
          % (sum(1 for _ in manifest_apps()), len(evidence['apps'])))
    print('Board electrical and acoustic validation still requires hardware.')
    print(report)
    return 0


if __name__ == '__main__':
    sys.exit(main())
