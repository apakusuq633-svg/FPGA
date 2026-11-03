#!/usr/bin/env python3
"""Read-only pre-board audit; passing software never implies physical acceptance.

Reads source/build/test/release evidence and writes only its own JSON result.
Does not build, program hardware, contact the board, or validate a real model.
Exit0 means the software package is consistent for guarded bring-up; physical
fault-direction acceptance is deliberately a separate, unverified result.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_UNITS = ("ps_ui", "gsc9", "pdm_stream", "circular9_stream",
                    "circular9_audio", "circular9_candidates", "circular9_diagnosis")
EVIDENCE = {
    "localizer": ("circular9_checks", "digital_checks.json"),
    "direction": ("circular9_direction_checks", "direction_checks.json"),
    "separation": ("circular9_candidates_checks", "separation_checks.json"),
    "diagnosis": ("circular9_diagnosis_checks", "diagnosis_checks.json"),
    "pipeline": ("circular9_pipeline_checks", "pipeline_checks.json"),
    "pdm_gsc": ("circular9_e2e", "pdm_to_gsc_checks.json"),
    "proposals": ("circular9_proposals_checks", "proposals_checks.json"),
    "tracking": ("circular9_tracking_checks", "tracking_checks.json"),
    "envelope": ("circular9_envelope_checks", "envelope_checks.json"),
    "gsc": ("gsc9_checks", "gsc_regression.json"),
    "loader": ("circular9_loader_checks", "loader_checks.json"),
    "calibration": ("circular9_calibration_checks", "calibration_checks.json"),
    "preflight": ("circular9_preflight_checks", "preflight_checks.json"),
    "receiver": ("circular9_receive_checks", "receiver_checks.json"),
    "model_release": ("circular9_model_release_checks", "model_release_checks.json"),
    "gsc_hotpath": ("gsc9_hotpath_checks", "gsc_hotpath_checks.json"),
    "control_rtl": ("circular9_control_checks", "control_rtl_checks.json"),
    "ps_control": ("circular9_ps_control_checks", "ps_control_checks.json"),
    "schedule": ("circular9_schedule_checks", "schedule_checks.json"),
    "aux": ("circular9_aux_checks", "aux_checks.json"),
}
LIVE_COPIES = {
    "pl.bit": "build/c9opt/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit",
    "hardware.xsa": "build/circular9_optimized_hw/das_fir.xsa",
    "routed_source_proof.json": "build/circular9_optimized_hw/routed_source_proof.json",
    "ps_ui.elf": "build/ui_pipeline_circular9/ui.elf",
    "ps_build.json": "build/ui_pipeline_circular9/build_manifest.json",
    "rv32.elf": "build/circular9/fw/fw_circular9.elf",
    "rv32_itcm.hex": "build/circular9/fw/itcm.hex",
    "rv32_dtcm.hex": "build/circular9/fw/dtcm.hex",
    "srp_lut.hex": "build/circular9/srp_lut.hex",
    "steer_lut.hex": "build/circular9/steer_lut.hex",
    "bearing.json": "configs/bearing_6004_2zr.json",
    "timing.rpt": "build/circular9_optimized_hw/timing_zynq.rpt",
    "utilization.rpt": "build/circular9_optimized_hw/util_zynq.rpt",
    "io.rpt": "build/circular9_optimized_hw/io_zynq.rpt",
    "circular9_dataset.py": "pc/circular9_dataset.py",
    "latency_contract.md": "docs/circular9_latency_contract_20261023.md",
    "original_plan.md": "docs/circular9_fault_localization_plan_20261022.md",
    "board_bringup.md": "docs/circular9_board_bringup_20261024.md",
    "direction_scan.md": "docs/circular9_direction_scan_20261025.md",
    "diagnosis_workflow.md": "docs/circular9_diagnosis_data_workflow_20261025.md",
    "direction_separation.md": "docs/circular9_direction_separation_20261025.md",
    "optimization.md": "docs/circular9_optimization_20261025.md",
    "optimization_completion.md": "docs/circular9_optimization_completion_20261025.md",
    "gsc_hotpath_guard.md": "docs/gsc9_hotpath_guard_20261025.md",
    "spectral_covariance.md": "docs/circular9_spectral_covariance_20261025.md",
    "circular9_receive.py": "pc/circular9_receive.py",
    "circular9_capture.py": "pc/circular9_capture.py",
    "circular9_preflight.py": "pc/circular9_preflight.py",
    "circular9_calibration.py": "scripts/circular9_calibration.py",
    "build_circular9.py": "scripts/build_circular9.py",
    "preflight_workflow.md": "docs/circular9_preflight_20261025.md",
    "calibration_workflow.md": "docs/circular9_calibration_input_20261025.md",
    "packet_capture.md": "docs/circular9_packet_capture_20261025.md",
    "readiness.md": "docs/circular9_readiness_20261025.md",
}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def relative_path(root, name):
    """Evidence filenames use either Windows or POSIX separators."""
    path = Path(root) / str(name).replace("\\", "/")
    resolved = path.resolve()
    if not resolved.is_relative_to(Path(root).resolve()):
        raise ValueError("source evidence leaves project root: " + str(name))
    return path


def source_hash_problems(root, document, allowed_external=None):
    hashes = document.get("source_sha256", document.get("sources", {}))
    if not hashes:
        return ["no source hash evidence"]
    problems = []
    for name, digest in hashes.items():
        try:
            try:
                path = relative_path(root, name)
            except ValueError:
                # Only the firmware manifest's exact config/evidence bindings
                # can name external files. Never allow arbitrary absolute paths.
                path = Path(str(name).replace("\\", "/")).resolve()
                if not allowed_external or allowed_external.get(str(path)) != digest:
                    raise ValueError("unbound external source evidence: " + name)
            if not path.is_file() or sha(path) != digest:
                problems.append("stale or missing source: " + name)
        except (OSError, ValueError) as error:
            problems.append(str(error))
    return problems


def production_dependencies(root):
    """Follow local quoted includes, including headers introduced after a build.

    This deliberately includes inactive local branches: over-recording an existing
    source is safe; silently overlooking a new production include is not.
    BSP/system includes are validated through the matched platform artifacts.
    """
    root = Path(root)
    pending = [root / "sw" / (name + ".c") for name in PRODUCTION_UNITS]
    found = set()
    while pending:
        path = pending.pop()
        key = path.relative_to(root).as_posix()
        if key in found:
            continue
        if not path.is_file():
            raise ValueError("missing production translation unit: " + key)
        found.add(key)
        for include in re.findall(r'^\s*#\s*include\s*"([^"\n]+)"', path.read_text(encoding="utf-8", errors="replace"), re.M):
            local = path.parent / include
            shared = root / "sw" / include
            if local.is_file():
                pending.append(local)
            elif shared.is_file():
                pending.append(shared)
    return found


def evidence_passed(document, *, localizer=False):
    if localizer:
        tests = document.get("tests", {})
        return bool(tests) and all(t.get("passed") is True for t in tests.values())
    return document.get("passed") is True or document.get("status") in ("PASS_DIGITAL", "PASS_NATIVE")


def elf_symbol_info(image, name):
    """Inspect one ELF32LE symbol, including large NOLOAD/NOBITS allocations."""
    if len(image) < 52 or image[:6] != b"\x7fELF\x01\x01":
        raise ValueError("symbol inspection requires ELF32 little-endian")
    offset = struct.unpack_from("<I", image, 32)[0]
    stride, count = struct.unpack_from("<HH", image, 46)
    if stride < 40 or offset + stride * count > len(image):
        raise ValueError("invalid ELF section table bounds")
    sections = [struct.unpack_from("<10I", image, offset + stride * i) for i in range(count)]
    def data(section):
        start, size = section[4], section[5]
        if start + size > len(image):
            raise ValueError("invalid ELF section bounds")
        return image[start:start + size]
    matches = []
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB; do not infer values from raw byte searches.
            continue
        if section[6] >= count or section[9] < 16:
            raise ValueError("invalid ELF symbol/string-table bounds")
        symbols, strings = data(section), data(sections[section[6]])
        if len(symbols) % section[9]:
            raise ValueError("partial ELF symbol entry")
        for index in range(0, len(symbols), section[9]):
            name_offset, value, size, _info, _other, target = struct.unpack_from("<IIIBBH", symbols, index)
            if name_offset >= len(strings):
                raise ValueError("invalid ELF symbol name")
            end = strings.find(b"\0", name_offset)
            if end < 0:
                raise ValueError("unterminated ELF symbol name")
            if strings[name_offset:end] != name.encode("ascii"):
                continue
            if not 0 < target < count:
                raise ValueError("symbol is not backed by an ELF section")
            backing = sections[target]
            start = value - backing[3]
            if start < 0 or start + size > backing[5]:
                raise ValueError("symbol leaves its ELF section")
            matches.append({"address": value, "size": size, "section_index": target,
                            "symbol_file_offset": section[4] + index,
                            "section_file_offset": offset + stride * target,
                            "section_address": backing[3], "section_size": backing[5],
                            "section_type": backing[1], "section_flags": backing[2],
                            "sections": sections,
                            "data": None if backing[1] == 8 else data(backing)[start:start + size]})
    if len(matches) != 1:
        raise ValueError("expected exactly one ELF symbol: " + name)
    return matches[0]


def elf_symbol_data(image, name):
    """Read actual initialized bytes; a NOBITS symbol is not initialized data."""
    info = elf_symbol_info(image, name)
    if info["data"] is None:
        raise ValueError("ELF symbol has no initialized bytes: " + name)
    return info["data"]


def shared_memory_problems(image):
    """Verify actual ARM linker isolation; this does not measure live cache use."""
    problems, allocations = [], {}
    for name, address, size in (("c9_ddr", 0x08000000, 0x100000),
                                ("c9_tasks_shared", 0x09000000, 0x100000),
                                ("c9_history_shared", 0x0a000000, 0x2000000)):
        symbol = elf_symbol_info(image, name)
        allocations[name] = {key: symbol[key] for key in
                             ("address", "size", "section_address", "section_size", "section_type")}
        if (symbol["address"] != address or symbol["size"] != size or
                symbol["section_address"] != address or symbol["section_size"] != size or
                symbol["section_type"] != 8 or symbol["section_flags"] & 3 != 3):
            problems.append("shared allocation is not the isolated expected NOLOAD section: " + name)
        for index, section in enumerate(symbol["sections"]):
            if index == symbol["section_index"] or not section[2] & 2 or not section[5]:
                continue
            if max(section[3], address) < min(section[3] + section[5], address + size):
                problems.append("another allocated ELF section overlaps shared reservation: " + name)
    return problems, allocations


def routed_source_problems(root, proof, bit, xsa):
    """Check a fresh complete routed snapshot, rather than a legacy .v-only set."""
    root = Path(root)
    files = [*(root / "rtl").rglob("*.v"), *(root / "rtl").rglob("*.vh"),
             *(root / "constrs").rglob("*.xdc"), *(root / "scripts").glob("*.tcl"),
             root / "scripts/filelist.f", root / "scripts/circular9_routed_evidence.py"]
    expected = {path.relative_to(root).as_posix() for path in files}
    recorded = {name.replace("\\", "/") for name in proof.get("source_sha256", {})}
    problems = source_hash_problems(root, proof)
    if recorded != expected:
        problems.append("routed source snapshot does not cover exactly all RTL/headers/XDC/TCL/filelist/evidence tool")
    if proof.get("status") != "ROUTED_SOURCE_AND_XSA_MATCHED":
        problems.append("fresh routed proof does not report matched source and XSA")
    if proof.get("bit_sha256") != sha(bit) or proof.get("xsa_sha256") != sha(xsa):
        problems.append("routed source proof is bound to different bitstream or XSA bytes")
    return problems


def model_abi2_bytes(model=None):
    """Cortex-A9 ABI2 struct: five uint32,pad4,80 doubles,two uint32,112mask words."""
    if model is None:
        return bytes(1120)
    values = [model[name] for name in ("abi", "feature_contract", "version", "kind", "validated")]
    doubles = [model[name] for name in ("shaft_hz_min", "shaft_hz_max", "rms_min")]
    doubles += [value for row in model["center"] for value in row]
    doubles += model["inverse_variance"] + model["radius"]
    doubles += [model["minimum_margin"], model["anomaly_multiplier"]]
    masks = [value for row in model["allowed_masks"] for value in row]
    masks += [0] * (112 - len(masks))
    return struct.pack("<5I4x80d2I112I", *values, *doubles, model["separation_contract"], model["mask_count"], *masks)


def audit(root=ROOT, release=None):
    root = Path(root).resolve()
    release = Path(release or root / "build/circular9_direction_release").resolve()
    checks, facts = [], {}

    def check(name, function):
        try:
            problems, details = function()
        except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, struct.error) as error:
            problems, details = [str(error)], {}
        checks.append({"name": name, "passed": not problems, "problems": problems, "details": details})

    def configuration():
        firmware = load_json(root / "build/circular9/build_manifest.json")
        config = Path(firmware["config_path"])
        if not config.is_absolute():
            raise ValueError("firmware config_path must be absolute")
        if sha(config) != firmware["config_sha256"]:
            raise ValueError("active configuration differs from its firmware binding")
        allowed_external = {str(config.resolve()): firmware["config_sha256"]}
        for path, digest in firmware.get("calibration_evidence_sha256", {}).items():
            bound = Path(path)
            if not bound.is_absolute() or sha(bound) != digest:
                raise ValueError("calibration evidence differs from its exact firmware binding: " + path)
            allowed_external[str(bound.resolve())] = digest
        facts["config_path"], facts["allowed_external"] = config, allowed_external
        array = load_json(config)
        bearing = load_json(root / "configs/bearing_6004_2zr.json")
        facts["array"], facts["bearing"] = array, bearing
        expected = {"channels": 9, "physical_mics": 9, "capture_slots": 10, "pairs": 36,
                    "sample_rate_hz": 156250, "pdm_decimation": 16, "window_samples": 1024,
                    "localizer_hop": 512, "scan_model": "far_field_direction",
                    "front_hemisphere_only": True}
        problems = [f"profile mismatch: {name}" for name, value in expected.items() if array.get(name) != value]
        if bearing.get("feature_contract") != "C9F2" or bearing.get("separation_contract") != "C9S3":
            problems.append("bearing feature/separation contract is not C9F2/C9S3")
        if sha(root / "docs/circular9_fault_localization_plan_20261022.md") != array.get("plan_sha256"):
            problems.append("original implementation-plan hash changed")
        return problems, {"scan": array.get("scan_model"), "feature_contract": bearing.get("feature_contract"),
                          "separation_contract": bearing.get("separation_contract")}
    check("profile_and_original_plan", configuration)

    def builds():
        firmware = load_json(root / "build/circular9/build_manifest.json")
        ps = load_json(root / "build/ui_pipeline_circular9/build_manifest.json")
        facts["firmware"], facts["ps"] = firmware, ps
        from circular9_model_release import inspect_model_release
        model_release = inspect_model_release(ps)
        facts["compiled_model"] = model_release
        allowed_external = dict(facts.get("allowed_external", {}))
        allowed_external.update(model_release["evidence_source_sha256"])
        allowed_external.update({str(path.resolve()): sha(path) for path in model_release["files"].values()})
        facts["allowed_external"] = allowed_external
        problems = source_hash_problems(root, firmware, allowed_external) + source_hash_problems(root, ps, allowed_external)
        recorded = {name.replace("\\", "/") for name in ps.get("source_sha256", {})}
        missing = production_dependencies(root) - recorded
        problems.extend("production include not recorded by PS build: " + name for name in sorted(missing))
        if firmware.get("simulation_only") or firmware.get("localizer_abi") != "P9D2" or firmware.get("hop_samples") != 512:
            problems.append("RV32 is not production P9D2 overlap512")
        elf = root / "build/ui_pipeline_circular9/ui.elf"
        image = elf.read_bytes()
        if sha(elf) != ps.get("elf_sha256"):
            problems.append("PS ELF differs from build evidence")
        if len(image) < 52 or image[:5] != b"\x7fELF\x01" or struct.unpack_from("<H", image, 18)[0] != 40:
            problems.append("PS artifact is not a 32-bit ARM ELF")
        memory_problems, allocations = shared_memory_problems(image)
        problems.extend(memory_problems)
        for name in ("build/circular9/fw/itcm.hex", "build/circular9/srp_lut.hex", "build/circular9/steer_lut.hex"):
            data = [int(word, 16) for word in (root / name).read_text().split()]
            if struct.pack("<" + "I" * len(data), *data) not in image:
                problems.append("PS loader embeds different RV32/LUT bytes: " + name)
        header = ps.get("diagnostic_model_header")
        if header:
            model_path = Path(header)
            if not model_path.is_absolute():
                model_path = root / model_path
            if sha(model_path) != ps.get("diagnostic_model_sha256"):
                problems.append("explicit diagnostic model differs from its build evidence")
        model = load_json(model_release["files"]["diagnostic_model.json"])["model"] if model_release["files"] else None
        actual_model = elf_symbol_data(image, "c9_configured_diag_model")
        if model is not None and actual_model != model_abi2_bytes(model):
            problems.append("actual ARM ELF model bytes differ from selected paired model artifacts")
        if model is None and (len(actual_model) != 1120 or struct.unpack_from("<3I", actual_model, 8) != (0, 0, 0)):
            problems.append("no-model ARM ELF contains nonzero model version/kind/validation state")
        return problems, {"ps_elf_sha256": sha(elf), "production_dependencies": len(production_dependencies(root)),
                          "explicit_model_header": bool(header), "compiled_model_bytes_verified": len(actual_model),
                          "shared_memory_allocations": allocations, "history_capacity_samples": 1048576,
                          "live_cache_behavior_measured": False,
                          "model_status": model_release["status"], "physical_validation_implied": False}
    check("production_build_and_include_closure", builds)

    def digital():
        problems, summaries = [], {}
        for name, (directory, _) in EVIDENCE.items():
            result = load_json(root / "build" / directory / "results.json")
            facts[name] = result
            if not evidence_passed(result, localizer=name == "localizer"):
                problems.append(name + ": evidence does not report passed tests")
            problems.extend(name + ": " + problem for problem in source_hash_problems(root, result, facts.get("allowed_external")))
            summaries[name] = {"passed": evidence_passed(result, localizer=name == "localizer"),
                               "source_files": len(result.get("source_sha256", result.get("sources", {})))}
        test = facts["localizer"]
        if test.get("firmware_sha256") != sha(root / "build/circular9/fw/itcm.hex"):
            problems.append("localizer test has different production RV32 bytes")
        latency = test.get("latency", {})
        if not 0 < latency.get("first_aligned_pcm_to_even_rv32_publication_ms_max", 999) < 10:
            problems.append("aligned-PCM to RV32 digital latency does not meet10ms")
        if latency.get("capture_drops") != 0 or latency.get("audio_drops") != 0:
            problems.append("digital acquisition evidence contains drops")
        pdm = facts["pdm_gsc"]
        if pdm.get("firmware_sha256") != test.get("firmware_sha256"):
            problems.append("PDM fixture and localizer use different RV32 images")
        for name, digest in pdm.get("lut_sha256", {}).items():
            if sha(root / "build/circular9" / name) != digest:
                problems.append("PDM fixture has different direction LUT: " + name)
        schedule = facts["schedule"]
        if (schedule.get("hop_raw_samples") != 80000 or schedule.get("hop_seconds") != .512 or
                schedule.get("observation_seconds") != 1.024 or schedule.get("latest_only") is not True):
            problems.append("diagnostic scheduler evidence is not 1.024s observation/512ms sample-domain latest-only")
        aux = facts["aux"]
        if (aux.get("hop_raw_samples") != 8192 or aux.get("window_raw_samples") != 16640 or
                aux.get("maximum_feedback_age_samples") != 31250 or aux.get("CPU0_FFT") is not False):
            problems.append("auxiliary search evidence does not match independent bounded CPU1 search")
        return problems, {"checks": summaries, "latency_scope": "first_aligned_PCM_to_stable_RV32_only",
                          "latency_ms_max": latency.get("first_aligned_pcm_to_even_rv32_publication_ms_max"),
                          "PS_receipt_or_fault_confirmation_proved": False}
    check("current_digital_evidence", digital)

    def package():
        manifest = load_json(release / "manifest.json")
        facts["release"] = manifest
        problems = []
        for name, item in manifest["files"].items():
            path = relative_path(release, name)
            if not path.is_file() or sha(path) != item.get("sha256") or path.stat().st_size != item.get("bytes"):
                problems.append("corrupt or missing release file: " + name)
        copies = dict(LIVE_COPIES)
        copies["array.json"] = str(facts["config_path"])
        copies.update({filename: "build/" + directory + "/results.json" for directory, filename in EVIDENCE.values()})
        for name, live in copies.items():
            if name not in manifest["files"] or sha(release / name) != sha(root / live):
                problems.append("release copy differs from current artifact/document: " + name)
        routed = load_json(release / "routed_source_proof.json")
        problems.extend(routed_source_problems(root, routed, release / "pl.bit", release / "hardware.xsa"))
        if manifest.get("routed_source_sha256") != routed.get("source_sha256"):
            problems.append("release routed-source snapshot differs from fresh complete routed proof")
        for name, digest in manifest.get("routed_rtl_sha256", {}).items():
            if sha(relative_path(root, name)) != digest:
                problems.append("RTL differs from routed-source evidence: " + name)
        routed_sources = {name.replace("\\", "/") for name in manifest.get("routed_rtl_sha256", {})}
        current_rtl = {p.relative_to(root).as_posix() for p in (root / "rtl").rglob("*.v")}
        if routed_sources != current_rtl:
            problems.append("routed RTL source set differs from current RTL source set")
        with zipfile.ZipFile(release / "hardware.xsa") as archive:
            embedded = [name for name in archive.namelist() if name.endswith(".bit")]
            if len(embedded) != 1 or hashlib.sha256(archive.read(embedded[0])).hexdigest() != sha(release / "pl.bit"):
                problems.append("XSA and release bitstream do not match")
        # Match the exact platform hardware supplied to the fresh BSP, rather than
        # trusting the name of its directory or the age of an ELF.
        bsp = Path(manifest["bsp_workspace"])
        hardware = list((bsp / "circular9/hw").glob("*.xsa"))
        if len(hardware) != 1 or sha(hardware[0]) != sha(release / "hardware.xsa"):
            problems.append("BSP hardware export differs from release XSA")
        if sha(bsp / "circular9/hw/ps7_init.tcl") != sha(release / "ps7_init.tcl"):
            problems.append("PS initialization script differs from matched BSP")
        if manifest.get("scan_model") != "far_field_direction" or manifest.get("feature_contract") != "C9F2" or manifest.get("separation_contract") != "C9S3":
            problems.append("release profile is not current direction/C9F2/C9S3")
        if manifest.get("source_snapshot_sha256") != facts.get("firmware", {}).get("source_sha256"):
            problems.append("release RV32 source snapshot differs from current build manifest")
        if manifest.get("ps_source_sha256") != facts.get("ps", {}).get("source_sha256"):
            problems.append("release PS source snapshot differs from current build manifest")
        model = facts.get("compiled_model", {})
        for key, expected in (("model_version", model.get("model_version")),
                              ("model_kind", model.get("model_kind")),
                              ("model_review_id", model.get("review_id")),
                              ("model_release_status", model.get("status")),
                              ("model_validation_source_sha256", model.get("evidence_source_sha256")),
                              ("classifier_validated", model.get("classifier_validated"))):
            if manifest.get(key) != expected:
                problems.append("release model provenance differs from compiled source evidence: " + key)
        if manifest.get("diagnostic_model_header", "") != facts.get("ps", {}).get("diagnostic_model_header", ""):
            problems.append("release selected model path differs from actual PS build")
        model_files = model.get("files", {})
        for name, source in model_files.items():
            if name not in manifest["files"] or sha(release / name) != sha(source):
                problems.append("release model artifact differs from exact compiled selection: " + name)
        for name in ("diagnostic_model.h", "diagnostic_model.json"):
            if name not in model_files and (name in manifest["files"] or (release / name).exists()):
                problems.append("no-model release contains stale model artifact: " + name)
        flow_log = root / "build/c9opt_console.log"
        raw = flow_log.read_bytes()
        text = raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", errors="replace")
        if sha(flow_log) != manifest.get("flow_log_sha256") or not re.search(r"^FLOW_PASS:", text, re.M) or re.search(r"^FLOW_FAIL:", text, re.M):
            problems.append("routed flow completion/log hash does not match release evidence")
        report = (release / "timing.rpt").read_text(encoding="utf-8", errors="replace")
        slacks = {}
        for kind in ("Setup", "Hold"):
            match = re.search(kind + r"\s*:\s*(\d+)\s+Failing Endpoints,\s+Worst Slack\s+([-\d.]+)ns", report)
            if not match or int(match[1]) != 0 or float(match[2]) < 0:
                problems.append("missing/failing routed " + kind + " timing")
            else:
                slacks[kind.lower() + "_slack_ns"] = float(match[2])
        return problems, {"directory": str(release), "files": len(manifest["files"]), **slacks}
    check("matched_release_and_routed_timing", package)

    array, bearing, release_manifest = facts.get("array", {}), facts.get("bearing", {}), facts.get("release", {})
    physical_gates = [
        {"gate": "physical_clock_and_power_measurements", "status": "UNVERIFIED",
         "microphone_part": array.get("microphone_part_number"),
         "datasheet_contract_reviewed": array.get("electrical_contract_reviewed", False),
         "required_evidence": "IM73D122 and3.3V/2.5MHz compatibility are confirmed; still measure actual board supply,CLK duty and DATA timing."},
        {"gate": "H1_DATA5_and_nine_independent_channels", "status": "UNVERIFIED",
         "configuration_flag": array.get("physical_mapping_confirmed", False),
         "required_evidence": "User confirms actual H1 signals are correct; still obtain independent excitation/channel mapping of all9 microphones and the active ninth-slot phase."},
        {"gate": "measured_geometry_and_calibration", "status": "UNVERIFIED",
         "configuration_status": array.get("geometry_status"), "calibration_version": array.get("calibration_version", 0),
         "required_evidence": "Measured acoustic-hole positions, orientation0deg/right/up convention, amplitude/phase calibration; production guard remains enabled."},
        {"gate": "PS_loaded_runtime_deadlines", "status": "UNVERIFIED",
         "manifest_measured": release_manifest.get("ps_runtime_latency_measured", False),
         "required_evidence": "Actual Cortex-A9 polling/receipt latency P95/P99/max and deadline misses under acquisition,GSC,diagnosis,HTTP/UDP load."},
        {"gate": "real_three_source_separation_and_features", "status": "UNVERIFIED",
         "required_evidence": "Single/dual/triple speaker angle ground truth; weak-fault-source cases; separated audio/SIR and fault-feature preservation across positions and levels."},
        {"gate": "real_fault_model_and_independent_validation", "status": "UNVERIFIED",
         "bearing_model_status": bearing.get("model_status"), "manifest_validated": release_manifest.get("classifier_validated", False),
         "required_evidence": "C9F2/C9S3 actual separated recordings with confirmed600-1800rpm, labels and recording-disjoint validation; no model remains unknown."},
        {"gate": "physical_direction_accuracy_and_continuity", "status": "UNVERIFIED",
         "required_evidence": "Known-angle error distribution,false faults,misses/rejections and sustained acquisition with no unexpected drops/freezes; actual acoustic-to-fault confirmation time separately."},
    ]
    software_ready = all(item["passed"] for item in checks)
    return {"schema": 2, "status": "SOFTWARE_READY_PHYSICAL_UNVERIFIED" if software_ready else "SOFTWARE_NOT_READY_PHYSICAL_UNVERIFIED",
            "software_ready_for_guarded_bringup": software_ready,
            "physical_ready_for_fault_direction_acceptance": False,
            "hardware_was_contacted": False, "real_model_was_validated": False,
            "scope": "Read-only consistency audit; source hashes and synthetic evidence cannot certify real sound or hardware.",
            "checks": checks, "physical_gates": physical_gates,
            "next_stage": "Resolve electrical/channel gates before collecting calibration and three-source evidence; do not bypass geometry/model guards.",
            "audit_source_sha256": sha(Path(__file__))}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, default=ROOT / "build/circular9_direction_release")
    parser.add_argument("--output", type=Path, default=ROOT / "build/circular9_readiness/results.json")
    args = parser.parse_args(argv)
    result = audit(ROOT, args.release)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    failures = [check["name"] for check in result["checks"] if not check["passed"]]
    print(json.dumps({"status": result["status"], "software_ready": result["software_ready_for_guarded_bringup"],
                      "physical_ready": False, "failed_checks": failures, "output": str(args.output)}))
    return 0 if result["software_ready_for_guarded_bringup"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
