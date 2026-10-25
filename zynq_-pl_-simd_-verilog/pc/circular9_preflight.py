#!/usr/bin/env python3
"""Read-only, staged preflight for controlled circular-nine board experiments.

This checks evidence, not microphone independence or classification accuracy.
Offline replay can satisfy recorded conditions but can never qualify a live board.
No endpoint that changes RPM, steering, GSC or hardware state is called.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import struct
import time
import urllib.error
import urllib.request

from circular9_receive import decode
from circular9_capture import capture_records

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACKAGE = Path(__file__).resolve().parent if (Path(__file__).resolve().parent / "manifest.json").is_file() else ROOT / "build/circular9_direction_release"
STAGES = ("capture-ready", "localization-ready", "fault-diagnosis-ready")
ENDPOINTS = ("status", "gsc", "candidates", "heatmap")
FEATURE_CONTRACT = 0x43394632
SEPARATION_CONTRACT = 0x43395333


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("timezone-aware timestamp required")
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("timestamp lacks timezone")
    return result.timestamp()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def strict_json(data):
    def bad_constant(value):
        raise ValueError("nonfinite JSON constant: " + value)
    def pairs(items):
        out = {}
        for key, value in items:
            if key in out:
                raise ValueError("duplicate JSON key: " + key)
            out[key] = value
        return out
    return json.loads(data, parse_constant=bad_constant, object_pairs_hook=pairs)


def read_json(path):
    return strict_json(Path(path).read_text(encoding="utf-8-sig"))


def integer(value, low=0, high=0xffffffff):
    return isinstance(value, int) and not isinstance(value, bool) and low <= value <= high


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def enabled(value):
    return value is True or value == 1


def sha_string(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def advanced(before, after):
    return integer(before) and integer(after) and 0 < ((after - before) & 0xffffffff) < 0x80000000


def inspect_package(folder):
    folder = Path(folder).resolve()
    issues, manifest, config, build = [], {}, {}, {}
    try:
        manifest = read_json(folder / "manifest.json")
        if not isinstance(manifest, dict):
            raise ValueError("manifest must be an object")
        entries = manifest.get("files", {})
        if not isinstance(entries, dict) or not entries:
            raise ValueError("manifest.files missing")
        required = {"pl.bit", "hardware.xsa", "ps_ui.elf", "ps7_init.tcl", "array.json",
                    "rv32_itcm.hex", "srp_lut.hex", "steer_lut.hex", "ps_build.json"}
        issues.extend("missing packaged file: " + name for name in sorted(required - entries.keys()))
        for name, entry in entries.items():
            file = (folder / name.replace("\\", "/")).resolve()
            if not file.is_relative_to(folder):
                issues.append("manifest path escapes package: " + name)
                continue
            if not isinstance(entry, dict) or not sha_string(entry.get("sha256")):
                issues.append("invalid file hash: " + name)
                continue
            if not file.is_file():
                issues.append("missing file: " + name)
            elif file.stat().st_size != entry.get("bytes") or digest(file) != entry["sha256"]:
                issues.append("file differs from manifest: " + name)
        config = read_json(folder / "array.json")
        build = read_json(folder / "ps_build.json")
        if not isinstance(config, dict) or not isinstance(build, dict):
            raise ValueError("array/PS build metadata must be objects")
        if build.get("elf_sha256") != entries.get("ps_ui.elf", {}).get("sha256"):
            issues.append("PS build manifest and ELF disagree")
        definitions = build.get("definitions", [])
        if "-DUI_DAS_ACTIVE_CHANNELS=9" not in definitions or "-DUI_DAS_LIVE=1" not in definitions:
            issues.append("PS build is not live nine-channel capture")
    except (OSError, ValueError, TypeError, AttributeError) as error:
        issues.append(str(error))
    manifest = manifest if isinstance(manifest, dict) else {}
    config = config if isinstance(config, dict) else {}
    build = build if isinstance(build, dict) else {}
    return {"path": str(folder), "manifest": manifest, "config": config, "build": build,
            "issues": issues, "manifest_sha256": digest(folder / "manifest.json") if (folder / "manifest.json").is_file() else None}


def inspect_recording(folder):
    """Independently recheck the existing receiver's original packet stream."""
    result = {"provided": True, "passed": False, "packets": 0, "samples": 0, "issues": []}
    prior = None
    sums, squares, clipped = [0]*9, [0]*9, [0]*9
    original_digest = hashlib.sha256()
    try:
        manifest = read_json(Path(folder) / "manifest.json")
        if not isinstance(manifest, dict):
            raise ValueError("recording manifest must be an object")
        if (manifest.get("raw_channels"), manifest.get("sample_rate_num"), manifest.get("sample_rate_den")) != (9, 156250, 1):
            raise ValueError("recording profile/rate differs")
        for payload in capture_records(Path(folder) / "packets.c9", digest=original_digest):
            header, rows = decode(payload)
            result["packets"] += 1
            if header["dma_drops"] or header["software_drops"]:
                raise ValueError("recording includes transport drops")
            for row in rows:
                identity = (header["session"], row["epoch"], header["geometry_version"], header["calibration_version"])
                if prior and (identity != prior[0] or not advanced(prior[1], row["sample"]) or
                              ((row["sample"] - prior[1]) & 0xffffffff) != 1 or row["timestamp"] - prior[2] != 256):
                    raise ValueError("session/configuration change, gap or unexpected sample clock")
                if row["tap_drops"] or row["dma_drops"]:
                    raise ValueError("recording includes upstream drops")
                if (header["unverified"] and row["trusted"]) or (row["reason"] == 0 and not row["trusted"]):
                    raise ValueError("trusted/adaptive audio contradicts direction qualification")
                for channel, value in enumerate(row["raw"]):
                    sums[channel] += value
                    squares[channel] += value*value
                    clipped[channel] += value in (-32768, 32767)
                result["samples"] += 1
                prior = (identity, row["sample"], row["timestamp"])
        if not prior or result["samples"] < 1024:
            raise ValueError("at least1024 original samples required")
        if manifest.get("invalid_packets") != 0 or manifest.get("samples") != result["samples"]:
            raise ValueError("receiver summary and original packets disagree")
        variance = [squares[ch]/result["samples"] - (sums[ch]/result["samples"])**2 for ch in range(9)]
        result.update(channel_ac_rms_pcm=[math.sqrt(max(0, value)) for value in variance], clipped_input_samples=clipped)
        if any(clipped) or any(value < 1 for value in variance):
            raise ValueError("clipped or constant/insufficiently excited original microphone channel")
        result.update(geometry_version=prior[0][2], calibration_version=prior[0][3], passed=True,
                      packets_sha256=original_digest.hexdigest(), manifest_sha256=digest(Path(folder) / "manifest.json"))
    except (OSError, ValueError, TypeError, KeyError, struct.error) as error:
        result["issues"].append(str(error))
    return result


def collect(base_url, rounds=3, interval=1.0, timeout=3.0):
    evidence = {"schema": 1, "source": "live_http", "collected_at": utc_now(), "url": base_url,
                "rounds": []}
    for index in range(rounds):
        response_set = {"started_at": utc_now(), "responses": {}}
        for endpoint in ENDPOINTS:
            start = time.monotonic()
            try:
                request = urllib.request.Request(base_url.rstrip("/") + "/api/" + endpoint,
                                                 headers={"Cache-Control": "no-cache"})
                with urllib.request.urlopen(request, timeout=timeout) as response:
                    payload = response.read(256 * 1024 + 1)
                    if len(payload) > 256 * 1024:
                        raise ValueError("response exceeds preflight bound")
                    if "application/json" not in response.headers.get("Content-Type", ""):
                        raise ValueError("endpoint did not return JSON")
                    data = strict_json(payload.decode("utf-8-sig"))
                    if not isinstance(data, dict):
                        raise ValueError("endpoint JSON must be an object")
                    item = {"http_status": response.status, "data": data}
            except (OSError, ValueError, UnicodeError) as error:
                item = {"error": str(error)}
            item["elapsed_ms"] = round((time.monotonic() - start) * 1000, 3)
            response_set["responses"][endpoint] = item
        evidence["rounds"].append(response_set)
        if index + 1 < rounds:
            time.sleep(interval)
    evidence["completed_at"] = utc_now()
    return evidence


def review_template():
    return {"schema": 1, "board_id": "UNCONFIRMED", "review_id": "", "reviewed_at": "",
            "electrical": {"microphone_brand": "Infineon", "microphone_chip_model": "IM73D122", "measured_supply_volts": None,
                           "chip_supply_clock_rating_checked": True, "measured_clock_hz": None,
                           "measured_clock_duty_percent": None, "data5_independent_verified": False,
                           "fpga_header_wiring_checked": False,
                           "data5_wiring_report": "User reports real wiring correct; H1 schematic label is wrong. Independent ninth-channel response remains to be checked."},
            "deployment": {"loaded_package_verified": False, "package_manifest_sha256": "",
                           "pl_bit_sha256": "", "ps_elf_sha256": ""},
            "localization": {"channel_mapping_verified": False, "sound_hole_coordinates_verified": False,
                             "amplitude_phase_calibration_verified": False, "calibration_version": 0,
                             "calibration_review_id": ""},
            "diagnosis": {"model_version": 0, "model_validation_review_id": "", "rpm": None,
                          "rpm_source": ""},
            "note": "Fill only from actual measurements/review. Booleans are operator attestations, not automatic hardware proof."}


def evaluate(package, evidence, review=None, recording=None, *, now=None, live=False, max_age=300):
    now = time.time() if now is None else now
    checks, notes = [], []
    def check(stage, name, okay, detail):
        checks.append({"stage": stage, "id": name, "passed": bool(okay), "detail": detail})
    manifest, config = package["manifest"], package["config"]
    check(STAGES[0], "package_integrity", not package["issues"], package["issues"] or "All listed files match SHA256 and size")
    expected = {"sample_rate_hz": 156250, "pdm_decimation": 16, "pdm_clock_hz": 2500000,
                "window_samples": 1024, "localizer_hop": 512, "channels": 9, "capture_slots": 10,
                "active_mask": 511, "pairs": 36, "grid_w": 32, "scan_model": "far_field_direction", "ring_radius_m": .03}
    check(STAGES[0], "package_profile", all(config.get(k) == v for k, v in expected.items()) and
          manifest.get("abi") == "P9D2" and manifest.get("feature_contract") == "C9F2" and
          manifest.get("separation_contract") == "C9S3", "Require production P9D2, C9F2/C9S3, DECIM16, Fs156250, N1024/H512, nine channels/ten slots")
    rounds = evidence.get("rounds", []) if isinstance(evidence, dict) else []
    if not isinstance(rounds, list):
        rounds = []
    try:
        evidence_age = now - timestamp(evidence.get("completed_at", evidence.get("collected_at")))
    except (ValueError, TypeError, AttributeError):
        evidence_age = None
    check(STAGES[0], "evidence_fresh", evidence_age is not None and -60 <= evidence_age <= max_age,
          {"age_seconds": evidence_age, "maximum_seconds": max_age})
    check(STAGES[0], "multiple_observations", len(rounds) >= 2, "At least two independent read-only HTTP observation rounds")
    data = {endpoint: [] for endpoint in ENDPOINTS}
    for endpoint in ENDPOINTS:
        for round_ in rounds:
            responses = round_.get("responses", {}) if isinstance(round_, dict) else {}
            item = responses.get(endpoint, {}) if isinstance(responses, dict) else {}
            data[endpoint].append(item.get("data", {}) if isinstance(item, dict) and item.get("http_status") == 200 and isinstance(item.get("data"), dict) else {})
        stage = STAGES[0] if endpoint in ("status", "gsc") else STAGES[1] if endpoint == "heatmap" else STAGES[2]
        check(stage, "endpoint_" + endpoint, bool(data[endpoint]) and all(data[endpoint]), "/api/" + endpoint + " must return complete JSON/HTTP200 in every round")
    status = data["status"][-1] if data["status"] else {}
    gsc = data["gsc"][-1] if data["gsc"] else {}
    candidates = data["candidates"][-1] if data["candidates"] else {}
    heatmap = data["heatmap"][-1] if data["heatmap"] else {}
    runtime = {"localizer_abi": "P9D2", "pdm_decimation": 16, "window_samples": 1024,
               "capture_slots": 10, "active_channels": 9, "active_mask": 511,
               "sample_rate_num": 156250, "sample_rate_den": 1, "hop_samples": 512}
    check(STAGES[0], "runtime_profile", all(all(d.get(k) == v for k, v in runtime.items()) for d in data["gsc"]) and bool(data["gsc"]),
          "Runtime declares the matching capture/ABI contract; missing fields never default to success")
    files = manifest.get("files", {})
    expected_geometry = int(files.get("array.json", {}).get("sha256", "0")[:8], 16) if sha_string(files.get("array.json", {}).get("sha256")) else None
    check(STAGES[0], "runtime_package_binding", expected_geometry is not None and all(
        d.get("geometry_version") == expected_geometry and d.get("rv32_itcm_sha256") == files.get("rv32_itcm.hex", {}).get("sha256")
        for d in data["gsc"]) and bool(data["gsc"]), "Match runtime geometry version and embedded RV32 image hash to the selected package")
    check(STAGES[0], "live_capture", bool(data["status"]) and all(d.get("input_mode") == 2 and d.get("input_channels") == 9 and d.get("input_error") == 0 for d in data["status"]),
          "Live nine-channel input, no receiver error; replay is rejected")
    check(STAGES[0], "capture_progress", len(data["status"]) >= 2 and all(advanced(data["status"][i-1].get("received_blocks"), d.get("received_blocks")) and
        advanced(data["status"][i-1].get("mic_seq"), d.get("mic_seq")) for i, d in enumerate(data["status"]) if i),
        "Audio block and microphone snapshot counters must advance, including uint32 wrap")
    def channel_quality(d):
        vectors = [d.get(k) for k in ("mic_rms_ppm", "mic_peak_ppm", "mic_clipped")]
        return (enabled(d.get("mic_valid")) and integer(d.get("mic_seq"), 2) and not d["mic_seq"] & 1 and d.get("mic_frozen") == 0 and
                all(isinstance(v, list) and len(v) == 9 and all(number(x) for x in v) for v in vectors) and
                all(x >= 5 for x in vectors[0]) and all(0 < x < 950000 for x in vectors[1]) and all(x == 0 for x in vectors[2]))
    check(STAGES[0], "channel_quality", bool(data["status"]) and all(channel_quality(d) for d in data["status"]),
          "Excite all microphones at moderate level: nine finite nonzero RMS/peak values, no frozen or clipped channel; this does not prove independent mapping")
    counters = (("status", "pl_dropped"), ("status", "ps_dropped"), ("status", "discontinuities"),
                ("gsc", "dma_drops"), ("gsc", "udp_frames_dropped"), ("gsc", "clock_errors"))
    counter_valid = all(len(data[e]) >= 2 and integer(data[e][0].get(k)) and all(d.get(k) == data[e][0][k] for d in data[e]) for e, k in counters)
    check(STAGES[0], "no_new_drops_or_clock_errors", counter_valid, "No increasing/reset loss, discontinuity or clock-error counters during the probe")
    notes.extend("Historical nonzero counter " + e + "." + k + "=" + str(data[e][0].get(k)) for e, k in counters if data[e] and integer(data[e][0].get(k)) and data[e][0][k])
    review = review if isinstance(review, dict) else {}
    try:
        review_age = now - timestamp(review.get("reviewed_at"))
    except (ValueError, TypeError):
        review_age = None
    check(STAGES[0], "manual_review_identity", review.get("schema") == 1 and review.get("board_id") not in (None, "", "UNCONFIRMED") and bool(review.get("review_id")) and
          review_age is not None and -60 <= review_age <= 30*86400, "A board-specific, dated operator review is required; it is not inferred from channel activity")
    electrical = review.get("electrical", {})
    check(STAGES[0], "electrical_review", isinstance(electrical, dict) and electrical.get("microphone_chip_model") == "IM73D122" and
          number(electrical.get("measured_supply_volts")) and 1.62 <= electrical["measured_supply_volts"] <= 3.6 and
          number(electrical.get("measured_clock_hz")) and 2475000 <= electrical["measured_clock_hz"] <= 2525000 and
          number(electrical.get("measured_clock_duty_percent")) and 40 <= electrical["measured_clock_duty_percent"] <= 60 and
          all(electrical.get(k) is True for k in ("chip_supply_clock_rating_checked", "data5_independent_verified", "fpga_header_wiring_checked")),
          "Confirmed IM73D122 supports3.3V/2.5MHz; still require measured VDD, actual2.5MHz clock/duty, independent DATA_5 and development-board header wiring review")
    deployment = review.get("deployment", {})
    check(STAGES[0], "deployment_review", isinstance(deployment, dict) and deployment.get("loaded_package_verified") is True and
          deployment.get("package_manifest_sha256") == package["manifest_sha256"] and
          deployment.get("pl_bit_sha256") == files.get("pl.bit", {}).get("sha256") and
          deployment.get("ps_elf_sha256") == files.get("ps_ui.elf", {}).get("sha256"),
          "Operator confirms the exact package/bit/ELF loaded; HTTP metadata is not binary readback attestation")
    localization = review.get("localization", {})
    localization = localization if isinstance(localization, dict) else {}
    check(STAGES[1], "physical_localization_review", isinstance(localization, dict) and all(localization.get(k) is True for k in
          ("channel_mapping_verified", "sound_hole_coordinates_verified", "amplitude_phase_calibration_verified")) and bool(localization.get("calibration_review_id")),
          "Nine-microphone mapping, measured acoustic coordinates and actual amplitude/phase calibration review required")
    check(STAGES[1], "geometry_calibration", manifest.get("physical_geometry_confirmed") is True and config.get("physical_mapping_confirmed") is True and
          enabled(gsc.get("geometry_confirmed")) and gsc.get("calibration_status") == "measured_reviewed" and integer(gsc.get("calibration_version"), 1) and
          candidates.get("geometry_confirmed") == gsc.get("geometry_confirmed") and candidates.get("calibration_version") == gsc.get("calibration_version") and
          localization.get("calibration_version") == gsc.get("calibration_version"), "Package, running geometry/calibration and operator review must agree; calibration capture is allowed without these")
    map_ok = (heatmap.get("scan_model") == "far_field_direction" and heatmap.get("width") == 32 and
              isinstance(heatmap.get("scores"), list) and len(heatmap["scores"]) == 1024 and all(integer(x, -0x80000000, 0x7fffffff) for x in heatmap["scores"]) and max(heatmap["scores"]) > 0 and
              integer(heatmap.get("sequence"), 2) and not heatmap["sequence"] & 1 and number(heatmap.get("map_age_us")) and
              number(heatmap.get("stale_after_us")) and 0 <= heatmap["map_age_us"] <= heatmap["stale_after_us"] and
              integer(heatmap.get("reason")) and not heatmap["reason"] & (1 | 2 | 4 | 64))
    check(STAGES[1], "current_direction_map", map_ok and len(data["heatmap"]) >= 2 and
          advanced(data["heatmap"][0].get("sequence"), heatmap.get("sequence")), "Fresh advancing 32x32 direction map; silence, clipping and deadline rejection block localization, multi-source ambiguity alone does not")
    latency_ok = (gsc.get("latency_scope") == "first_pcm_to_first_ps_metadata_receipt" and gsc.get("single_window_deadline_us") == 10000 and
                  integer(gsc.get("valid_latency_samples"), 1) and integer(gsc.get("pcm_to_ps_max_us"), 1, 10000) and
                  gsc.get("deadline_misses") == 0 and gsc.get("location_stale") == 0 and gsc.get("clock_errors") == 0 and
                  len(data["gsc"]) >= 2 and advanced(data["gsc"][0].get("latency_samples"), gsc.get("latency_samples")))
    check(STAGES[1], "observed_metadata_deadline", latency_ok, "Observed first aligned PCM to first PS metadata receipt <=10ms; not cold start, sound propagation, UI display or diagnosis latency")
    contracts_ok = candidates.get("feature_contract") == FEATURE_CONTRACT and candidates.get("separation_contract") == SEPARATION_CONTRACT and candidates.get("diagnostic_window_ms") == 1024 and (candidates.get("sample_rate_num"), candidates.get("sample_rate_den")) == (78125, 2)
    check(STAGES[2], "diagnostic_contract", contracts_ok, "C9F2/C9S3, 40000 samples at39062.5Hz, 1.024s observation")
    diagnosis_review = review.get("diagnosis", {})
    diagnosis_review = diagnosis_review if isinstance(diagnosis_review, dict) else {}
    rpm = candidates.get("shaft_millihz")
    rpm_ok = (enabled(candidates.get("shaft_confirmed")) and integer(rpm, 10000, 30000) and isinstance(diagnosis_review, dict) and
              number(diagnosis_review.get("rpm")) and 600 <= diagnosis_review["rpm"] <= 1800 and
              abs(diagnosis_review["rpm"] - rpm*.06) <= .06 and bool(diagnosis_review.get("rpm_source")))
    check(STAGES[2], "confirmed_rpm", rpm_ok, "A current measured/operator-verified600..1800RPM setting must match the separately reviewed source")
    model_ok = (manifest.get("classifier_validated") is True and enabled(candidates.get("model_validated")) and
                integer(manifest.get("model_version"), 1) and integer(candidates.get("model_version"), 1) and
                manifest["model_version"] == candidates["model_version"] == diagnosis_review.get("model_version") and
                isinstance(manifest.get("model_review_id"), str) and bool(manifest["model_review_id"].strip()) and
                diagnosis_review.get("model_validation_review_id") == manifest["model_review_id"] and
                all(name in files for name in ("diagnostic_model.h", "diagnostic_model.json")))
    check(STAGES[2], "validated_diagnostic_model", model_ok, "Independent real normal/fault/interference validation required; package/runtime/operator model versions and exact validation review ID must match; baseline anomaly is not fault diagnosis")
    candidate_rows = candidates.get("candidates", [])
    if not isinstance(candidate_rows, list):
        candidate_rows = []
    fresh = integer(candidates.get("sequence"), 1) and number(candidates.get("result_age_ms")) and 0 <= candidates["result_age_ms"] <= 2000
    separation = candidates.get("separation", {})
    mask = separation.get("usable_mask", []) if isinstance(separation, dict) else []
    mask_ok = isinstance(mask, list) and len(mask) == 7 and all(integer(v) for v in mask) and mask[6] <= 1023 and any(mask)
    covered, max_gap, gap = 0, 0, 0
    if mask_ok:
        for bin_ in range(58, 121):
            okay = (mask[(bin_ - 8)//32] >> ((bin_ - 8) % 32)) & 1
            covered += okay
            gap = 0 if okay else gap + 1
            max_gap = max(max_gap, gap)
    sep_ok = (isinstance(separation, dict) and separation.get("invalid_input") == 0 and integer(separation.get("ready_mask"), 1, 7) and number(separation.get("max_weight_norm")) and 0 < separation["max_weight_norm"] <= 8 and
        number(separation.get("carrier_bins")) and separation["carrier_bins"] > 0 and number(separation.get("carrier_usable_bins")) and
        separation["carrier_usable_bins"] >= .95*separation["carrier_bins"] and integer(separation.get("carrier_max_gap"), 0, 3) and
        mask_ok and separation["carrier_bins"] == 63 and separation["carrier_usable_bins"] == covered and separation["carrier_max_gap"] == max_gap and
        number(separation.get("target_error")) and 0 <= separation["target_error"] < 1e-8 and
        number(separation.get("max_null_leakage")) and 0 <= separation["max_null_leakage"] <= .01 and
        number(separation.get("min_sector_gain")) and separation["min_sector_gain"] >= .85*.85 and
        number(separation.get("max_sector_gain")) and separation["max_sector_gain"] <= 1.15*1.15 and
        number(separation.get("max_sector_leakage")) and 0 <= separation["max_sector_leakage"] <= .03)
    bindings_ok = bool(candidate_rows) and len(candidate_rows) <= 3
    faults, guard_errors = [], []
    for index, row in enumerate(candidate_rows):
        row = row if isinstance(row, dict) else {}
        d = row.get("diagnosis", {})
        d = d if isinstance(d, dict) else {}
        b = d.get("binding", {}) if isinstance(d, dict) else {}
        features = d.get("features", [])
        extraction = d.get("extraction", {})
        features_ok = (isinstance(features, list) and len(features) == 18 and all(number(v) for v in features) and
                       isinstance(extraction, dict) and extraction.get("status") in (1, 3) and
                       extraction.get("carrier_low_hz") == 2200 and extraction.get("carrier_high_hz") == 4600 and
                       number(d.get("rms")) and d["rms"] > 0)
        bound = (isinstance(b, dict) and integer(row.get("grid"), 0, 1023) and integer(row.get("azimuth_mdeg"), -90000, 90000) and integer(row.get("elevation_mdeg"), -90000, 90000) and
                 integer(row.get("track_id"), 1) and b.get("track_id") == row.get("track_id") and b.get("grid") == row.get("grid") and
                 b.get("azimuth_mdeg") == row.get("azimuth_mdeg") and b.get("elevation_mdeg") == row.get("elevation_mdeg") and
                 b.get("epoch") == candidates.get("snapshot_epoch") and b.get("first_sample") == candidates.get("snapshot_first_sample") and
                 b.get("sample_count") == 40000 and b.get("flags") == 15 and d.get("feature_contract") == FEATURE_CONTRACT)
        eligible = (fresh and enabled(row.get("stable")) and row.get("stale") == 0 and enabled(row.get("separation_ready")) and
                    sep_ok and bound and features_ok and contracts_ok and rpm_ok and model_ok and d.get("model_kind") == 2 and
                    d.get("model_version") == candidates.get("model_version") and enabled(d.get("model_validated")) and
                    number(d.get("shaft_hz")) and abs(d["shaft_hz"] - rpm/1000) < .00001 and
                    integer(d.get("clipped_samples"), 0, 40) and enabled(gsc.get("geometry_confirmed")) and integer(gsc.get("calibration_version"), 1))
        bindings_ok = bindings_ok and fresh and bound and features_ok and d.get("model_kind") == 2 and row.get("stale") == 0 and enabled(row.get("stable")) and enabled(row.get("separation_ready"))
        if enabled(d.get("fault_direction_valid")):
            if not eligible or d.get("label") != "fault":
                guard_errors.append("fault direction cannot be substantiated by the supplied binding/model/review evidence at candidate" + str(index))
            else:
                faults.append({"track_id": row["track_id"], "azimuth_mdeg": row.get("azimuth_mdeg"), "elevation_mdeg": row.get("elevation_mdeg")})
        if d.get("label") == "fault" and not eligible:
            guard_errors.append("unqualified fault label at candidate" + str(index))
    check(STAGES[2], "current_bound_separated_candidates", fresh and sep_ok and bindings_ok, "Current stable candidate audio, common snapshot binding and contiguous supported carrier required")
    check(STAGES[0], "fault_rejection_consistent", not guard_errors, guard_errors or "No invalid fault-direction claims in the observed evidence")
    contradiction = candidates.get("target_mode") == "fault" and len(faults) != 1 and gsc.get("gsc_reason") == 0
    previous_contradiction = False
    if len(data["candidates"]) >= 2 and len(data["gsc"]) >= 2:
        previous = data["candidates"][-2]
        previous_rows = previous.get("candidates", [])
        previous_claims = sum(enabled(row.get("diagnosis", {}).get("fault_direction_valid")) and row.get("stale") == 0
                              for row in previous_rows if isinstance(row, dict) and isinstance(row.get("diagnosis"), dict)) if isinstance(previous_rows, list) else 0
        previous_contradiction = previous.get("target_mode") == "fault" and previous_claims != 1 and data["gsc"][-2].get("gsc_reason") == 0
    if contradiction and previous_contradiction:
        check(STAGES[0], "fault_target_withheld", False, "Two observations show active GSC in fault mode without a unique eligible fault; inspect target withdrawal and metadata")
    else:
        check(STAGES[0], "fault_target_withheld", True, "No active-GSC/invalid-fault contradiction observed; this is not physical steering readback")
        if contradiction:
            notes.append("One fault-target/GSC observation was inconsistent; endpoints are sampled sequentially. Repeat to distinguish a transition from sustained contradiction")
    if recording is not None:
        check(STAGES[0], "raw_recording", recording.get("passed") and recording.get("geometry_version") == expected_geometry and recording.get("calibration_version") == gsc.get("calibration_version"), recording)
    else:
        notes.append("No original C9C2 recording checked; use circular9_receive.py and rerun with --recording before recording acceptance")
    stage_report, previous = {}, True
    for stage in STAGES:
        blockers = [item["id"] for item in checks if item["stage"] == stage and not item["passed"]]
        good = previous and not blockers
        stage_report[stage] = {"conditions_satisfied": good, "ready_now": good and live,
                               "own_blockers": blockers, "prerequisite_satisfied": previous}
        previous = good
    return {"schema": 1, "generated_at": datetime.fromtimestamp(now, timezone.utc).isoformat(), "live_probe": bool(live),
            "board_acceptance": False, "package_manifest_sha256": package["manifest_sha256"],
            "stages": stage_report, "checks": checks, "observed_fault_directions": faults, "notes": notes,
            "recorded_evidence_level": next((stage for stage in reversed(STAGES) if stage_report[stage]["conditions_satisfied"]), "blocked"),
            "controlled_test_level": next((stage for stage in reversed(STAGES) if stage_report[stage]["ready_now"]), "blocked"),
            "identity_limit": "File hashes and declared HTTP profile plus operator deployment review; no authenticated PL/ELF memory readback",
            "timing_limit": "Short probe only; first aligned PCM-to-PS metadata timing excludes microphone latency, cold start and1.024s diagnosis observation"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    parser.add_argument("--url", default="http://192.168.2.10")
    parser.add_argument("--review", type=Path)
    parser.add_argument("--recording", type=Path)
    parser.add_argument("--offline", type=Path, help="Replay captured HTTP evidence; never qualifies a currently connected board")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--timeout", type=float, default=3)
    parser.add_argument("--max-age-seconds", type=float, default=300)
    parser.add_argument("--require-stage", choices=STAGES, default=STAGES[0])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--write-review-template", type=Path)
    args = parser.parse_args()
    if args.write_review_template:
        with args.write_review_template.open("x", encoding="utf-8") as target:
            json.dump(review_template(), target, ensure_ascii=False, indent=2)
            target.write("\n")
        return 0
    if not args.output:
        parser.error("--output is required; retain a separate report for each controlled test")
    if args.rounds < 2 or args.interval <= 0 or args.timeout <= 0 or args.max_age_seconds <= 0:
        parser.error("At least2 rounds and positive interval/timeout/age are required")
    if args.output.exists():
        parser.error("Output already exists; select a new report filename")
    package = inspect_package(args.package)
    evidence = read_json(args.offline) if args.offline else collect(args.url, args.rounds, args.interval, args.timeout)
    if args.offline and isinstance(evidence, dict) and "http_evidence" in evidence:
        evidence = evidence["http_evidence"]
    review = read_json(args.review) if args.review else None
    report = evaluate(package, evidence, review,
                      inspect_recording(args.recording) if args.recording else None,
                      live=not args.offline, max_age=args.max_age_seconds)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report["http_evidence"] = evidence
    report["package_evidence"] = {"path": package["path"], "manifest": package["manifest"]}
    report["review_evidence"] = {"path": str(args.review), "sha256": digest(args.review), "data": review} if args.review else None
    with args.output.open("x", encoding="utf-8") as output:
        json.dump(report, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write("\n")
    print("CIRCULAR9_PREFLIGHT " + report["controlled_test_level"])
    for stage, item in report["stages"].items():
        print(stage + ": " + ("READY" if item["ready_now"] else "RECORDED_CONDITIONS_ONLY" if item["conditions_satisfied"] else "BLOCKED") +
              (" (" + ", ".join(item["own_blockers"]) + ")" if item["own_blockers"] else ""))
    print("report=" + str(args.output))
    return 0 if report["stages"][args.require_stage]["ready_now"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
