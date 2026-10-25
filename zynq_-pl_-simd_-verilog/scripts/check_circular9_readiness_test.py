#!/usr/bin/env python3
"""Readiness negative controls; --helpers-only needs no build/release artifacts."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("c9readiness", ROOT / "scripts/check_circular9_readiness.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def elf_fixture():
    """Named independent ELF32 fixture: three NOLOAD regions and one model."""
    names = ("c9_ddr", "c9_tasks_shared", "c9_history_shared", "c9_configured_diag_model")
    addresses = (0x08000000, 0x09000000, 0x0a000000, 0x10000)
    sizes = (0x100000, 0x100000, 0x2000000, 1120)
    strings = b"\0"
    entries = [bytes(16)]
    for index, (name, address, size) in enumerate(zip(names, addresses, sizes), 1):
        entries.append(struct.pack("<IIIBBH", len(strings), address, size, 0x11, 0, index))
        strings += name.encode("ascii") + b"\0"
    model = bytearray(1120)
    struct.pack_into("<5I", model, 0, 2, 0x43394632, 0, 0, 0)
    data_offset = 52
    symbols = b"".join(entries)
    symbol_offset = data_offset + len(model)
    string_offset = symbol_offset + len(symbols)
    section_offset = (string_offset + len(strings) + 3) & ~3
    sections = [(0,) * 10]
    for address, size in zip(addresses[:3], sizes[:3]):
        sections.append((0, 8, 3, address, 0, size, 0, 0, 0x100000, 0))
    sections += [(0, 1, 2, addresses[3], data_offset, 1120, 0, 0, 8, 0),
                 (0, 2, 0, 0, symbol_offset, len(symbols), 6, 1, 4, 16),
                 (0, 3, 0, 0, string_offset, len(strings), 0, 0, 1, 0)]
    header = struct.pack("<16sHHIIIIIHHHHHH", b"\x7fELF\x01\x01\x01" + bytes(9),
                         2, 40, 1, addresses[3], 0, section_offset, 0, 52, 0, 0, 40, len(sections), 0)
    image = bytearray(header + model + symbols + strings)
    image.extend(bytes(section_offset - len(image)))
    image.extend(b"".join(struct.pack("<10I", *section) for section in sections))
    return bytes(image)


def helper_checks():
    image = elf_fixture()
    assert len(tool.EVIDENCE) == 20
    errors, memory = tool.shared_memory_problems(image)
    assert not errors, errors
    assert memory["c9_history_shared"]["size"] == 0x2000000
    compiled = tool.elf_symbol_data(image, "c9_configured_diag_model")
    assert len(compiled) == 1120 and struct.unpack_from("<3I", compiled, 8) == (0, 0, 0)
    history = tool.elf_symbol_info(image, "c9_history_shared")
    assert history["data"] is None
    for invalid, name in ((b"not an ELF", "c9_configured_diag_model"), (image, "c9_history_shared"),
                          (image, "no_such_symbol")):
        try:
            tool.elf_symbol_data(invalid, name)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid/NOLOAD symbol accepted as initialized bytes: " + name)
    undersized = bytearray(image)
    struct.pack_into("<I", undersized, history["symbol_file_offset"] + 8, 0x1000000)
    assert tool.shared_memory_problems(undersized)[0]
    overlap = bytearray(image)
    # The model section is allocated in a reserved history page; its symbol is
    # irrelevant to isolation. This catches an overlapping section independently.
    model = tool.elf_symbol_info(image, "c9_configured_diag_model")
    struct.pack_into("<I", overlap, model["section_file_offset"] + 12, 0x0a000100)
    assert tool.shared_memory_problems(overlap)[0]
    initialized = bytearray(image)
    struct.pack_into("<I", initialized, history["section_file_offset"] + 4, 1)
    try:
        errors, _ = tool.shared_memory_problems(initialized)
    except ValueError:
        pass
    else:
        assert errors, "initialized giant history reservation accepted"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / "source.c"
        source.write_text("version1", encoding="utf-8")
        evidence = {"source_sha256": {"source.c": tool.sha(source)}}
        assert not tool.source_hash_problems(root, evidence)
        source.write_text("version2", encoding="utf-8")
        assert tool.source_hash_problems(root, evidence)
        assert tool.source_hash_problems(root, {"source_sha256": {"../outside.c": "0" * 64}})
        assert tool.source_hash_problems(root, {})
        outside = root.parent / (root.name + "_bound_config.json")
        outside.write_text("{}", encoding="utf-8")
        try:
            bound = {str(outside.resolve()): tool.sha(outside)}
            record = {"source_sha256": dict(bound)}
            assert tool.source_hash_problems(root, record)
            assert not tool.source_hash_problems(root, record, bound)
            outside.write_text('{"changed":true}', encoding="utf-8")
            assert tool.source_hash_problems(root, record, bound)
        finally:
            outside.unlink()
        (root / "sw").mkdir()
        for unit in tool.PRODUCTION_UNITS:
            (root / "sw" / (unit + ".c")).write_text("", encoding="utf-8")
        (root / "sw/ps_ui.c").write_text('#include "new_private.h"\n', encoding="utf-8")
        (root / "sw/new_private.h").write_text('#include "nested.h"\n', encoding="utf-8")
        (root / "sw/nested.h").write_text("", encoding="utf-8")
        assert {"sw/new_private.h", "sw/nested.h"}.issubset(tool.production_dependencies(root))
        assert not tool.evidence_passed({"tests": {}}, localizer=True)
        assert not tool.evidence_passed({"tests": {"failed": {"passed": False}}}, localizer=True)
        assert not tool.evidence_passed({"status": "PASS_PHYSICAL"})
        for directory in ("rtl", "constrs", "scripts"):
            (root / directory).mkdir()
        routed_files = ["rtl/top.v", "rtl/params.vh", "constrs/pins.xdc",
                        "scripts/build.tcl", "scripts/filelist.f", "scripts/circular9_routed_evidence.py"]
        for name in routed_files:
            (root / name).write_text(name, encoding="utf-8")
        bit, xsa = root / "test.bit", root / "test.xsa"
        bit.write_bytes(b"named bit fixture");xsa.write_bytes(b"named XSA fixture")
        proof = {"status": "ROUTED_SOURCE_AND_XSA_MATCHED",
                 "source_sha256": {name: tool.sha(root / name) for name in routed_files},
                 "bit_sha256": tool.sha(bit), "xsa_sha256": tool.sha(xsa)}
        assert not tool.routed_source_problems(root, proof, bit, xsa)
        legacy = {**proof, "source_sha256": {"rtl/top.v": tool.sha(root / "rtl/top.v")}}
        assert tool.routed_source_problems(root, legacy, bit, xsa)
        (root / "rtl/params.vh").write_text("changed", encoding="utf-8")
        assert tool.routed_source_problems(root, proof, bit, xsa)
        (root / "rtl/params.vh").write_text("rtl/params.vh", encoding="utf-8")
        (root / "scripts/new.tcl").write_text("new synthesis input", encoding="utf-8")
        assert tool.routed_source_problems(root, proof, bit, xsa)
        (root / "scripts/new.tcl").unlink()
        assert tool.routed_source_problems(root, {**proof, "bit_sha256": "0" * 64}, bit, xsa)
        assert tool.routed_source_problems(root, {**proof, "status": "BEGIN_ONLY"}, bit, xsa)
    print("CIRCULAR9_READINESS_HELPERS_PASS independent_ELF32_32MiB_NOLOAD_overlap_complete_routed_set_stale_sources_bound_external_new_include")


def release_checks():
    # Deliberately fails for an old package, rather than validating a fake green
    # manifest. These tests copy the package and never modify the actual release.
    current = tool.audit()
    assert current["software_ready_for_guarded_bringup"], current["checks"]
    assert not current["physical_ready_for_fault_direction_acceptance"]
    assert not current["hardware_was_contacted"] and not current["real_model_was_validated"]
    assert all(item["status"] == "UNVERIFIED" for item in current["physical_gates"])
    image = (ROOT / "build/ui_pipeline_circular9/ui.elf").read_bytes()
    assert not tool.shared_memory_problems(image)[0]
    compiled = tool.elf_symbol_data(image, "c9_configured_diag_model")
    assert len(compiled) == 1120
    if not tool.load_json(ROOT / "build/ui_pipeline_circular9/build_manifest.json").get("diagnostic_model_header"):
        assert struct.unpack_from("<3I", compiled, 8) == (0, 0, 0)
    with tempfile.TemporaryDirectory() as directory:
        release = Path(directory) / "release"
        shutil.copytree(ROOT / "build/circular9_direction_release", release)
        elf = release / "ps_ui.elf"
        data = bytearray(elf.read_bytes());data[-1] ^= 1;elf.write_bytes(data)
        broken = tool.audit(ROOT, release)
        assert not broken["software_ready_for_guarded_bringup"]
        assert not broken["physical_ready_for_fault_direction_acceptance"]
        assert any("ps_ui.elf" in problem for check in broken["checks"] for problem in check["problems"])
        shutil.copyfile(ROOT / "build/circular9_direction_release/ps_ui.elf", elf)
        manifest = tool.load_json(release / "manifest.json")
        digital = release / "digital_checks.json"
        result = tool.load_json(digital)
        result["latency"]["first_aligned_pcm_to_even_rv32_publication_ms_max"] = 11
        digital.write_text(json.dumps(result), encoding="utf-8")
        manifest["files"]["digital_checks.json"] = {"sha256": tool.sha(digital), "bytes": digital.stat().st_size}
        (release / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        stale = tool.audit(ROOT, release)
        assert not stale["software_ready_for_guarded_bringup"]
        assert any("digital_checks.json" in problem for check in stale["checks"] for problem in check["problems"])
        shutil.copyfile(ROOT / "build/circular9_direction_release/digital_checks.json", digital)
        manifest = tool.load_json(ROOT / "build/circular9_direction_release/manifest.json")
        manifest.update(board_tested=True, physical_geometry_confirmed=True,
                        classifier_validated=True, ps_runtime_latency_measured=True)
        (release / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        claimed = tool.audit(ROOT, release)
        assert not claimed["physical_ready_for_fault_direction_acceptance"]
        assert all(item["status"] == "UNVERIFIED" for item in claimed["physical_gates"])
    print("CIRCULAR9_READINESS_TEST_PASS actual_release_ELF_corruption_rehashed_stale_copy_false_physical_claims")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helpers-only", action="store_true")
    args = parser.parse_args()
    helper_checks()
    if not args.helpers_only:
        release_checks()


if __name__ == "__main__":
    main()
