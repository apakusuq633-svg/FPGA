"""Offline qualification-tool tests; all board responses/reviews are fixtures."""
import copy
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import unittest
import zlib
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pc"))
import circular9_preflight as preflight

NOW = datetime(2026, 10, 25, 12, tzinfo=timezone.utc).timestamp()
STAMP = datetime.fromtimestamp(NOW, timezone.utc).isoformat()
OUT = ROOT / "build/circular9_preflight_checks"


def fixture_package(directory):
    directory = Path(directory)
    config = {"sample_rate_hz": 156250, "pdm_decimation": 16, "pdm_clock_hz": 2500000,
              "window_samples": 1024, "localizer_hop": 512, "channels": 9, "capture_slots": 10,
              "active_mask": 511, "pairs": 36, "grid_w": 32, "scan_model": "far_field_direction",
              "physical_mapping_confirmed": True, "ring_radius_m": .03}
    contents = {name: ("SYNTHETIC_TEST_ONLY:" + name).encode() for name in
                ("pl.bit", "hardware.xsa", "ps_ui.elf", "ps7_init.tcl", "rv32_itcm.hex", "srp_lut.hex", "steer_lut.hex")}
    contents["array.json"] = json.dumps(config).encode()
    contents["diagnostic_model.h"] = b"/*SYNTHETIC_MODEL_FIXTURE_ONLY*/"
    contents["diagnostic_model.json"] = json.dumps({"fixture_only": True, "model_version": 12, "review_id": "FIXTURE_MODEL"}).encode()
    contents["ps_build.json"] = json.dumps({"elf_sha256": hashlib.sha256(contents["ps_ui.elf"]).hexdigest(),
        "definitions": ["-DUI_DAS_ACTIVE_CHANNELS=9", "-DUI_DAS_LIVE=1"]}).encode()
    entries = {}
    for name, data in contents.items():
        (directory / name).write_bytes(data)
        entries[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    manifest = {"status": "FIXTURE_NOT_HARDWARE", "abi": "P9D2", "feature_contract": "C9F2", "separation_contract": "C9S3",
                "physical_geometry_confirmed": True, "classifier_validated": True,
                "model_version": 12, "model_review_id": "FIXTURE_MODEL", "files": entries}
    (directory / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    package = preflight.inspect_package(directory)
    assert not package["issues"], package["issues"]
    return package


def fixtures(package):
    geometry = int(package["manifest"]["files"]["array.json"]["sha256"][:8], 16)
    rounds = []
    for index in range(3):
        first = 100000 + index*400000
        status = {"input_mode": 2, "input_channels": 9, "input_error": 0, "received_blocks": 100 + index*100,
                  "mic_valid": 1, "mic_seq": 2 + index*2, "mic_frozen": 0, "mic_rms_ppm": [10000]*9,
                  "mic_peak_ppm": [100000]*9, "mic_clipped": [0]*9,
                  "pl_dropped": 0, "ps_dropped": 0, "discontinuities": 0}
        gsc = {"localizer_abi": "P9D2", "rv32_itcm_sha256": package["manifest"]["files"]["rv32_itcm.hex"]["sha256"],
               "geometry_version": geometry, "pdm_decimation": 16, "window_samples": 1024,
               "capture_slots": 10, "active_channels": 9, "active_mask": 511, "sample_rate_num": 156250,
               "sample_rate_den": 1, "hop_samples": 512, "geometry_confirmed": 1,
               "calibration_version": 77, "calibration_status": "measured_reviewed", "dma_drops": 0,
               "udp_frames_dropped": 0, "clock_errors": 0, "latency_samples": 1000 + index*300,
               "valid_latency_samples": 900 + index*300, "latency_scope": "first_pcm_to_first_ps_metadata_receipt",
               "single_window_deadline_us": 10000, "pcm_to_ps_max_us": 9600, "deadline_misses": 0,
               "location_stale": 0, "gsc_reason": 1}
        binding = {"track_id": 3, "grid": 528, "azimuth_mdeg": 2812, "elevation_mdeg": 2812,
                   "epoch": 4, "first_sample": first, "sample_count": 40000, "flags": 15}
        diagnosis = {"binding": binding, "feature_contract": preflight.FEATURE_CONTRACT, "model_kind": 2,
                     "model_version": 12, "model_validated": 1, "shaft_hz": 25, "label": "normal",
                     "fault_direction_valid": 0, "clipped_samples": 0, "rms": .01, "features": list(range(18)),
                     "extraction": {"status": 1, "carrier_low_hz": 2200, "carrier_high_hz": 4600}}
        candidate = {"track_id": 3, "grid": 528, "azimuth_mdeg": 2812, "elevation_mdeg": 2812,
                     "stable": 1, "stale": 0, "separation_ready": 1, "diagnosis": diagnosis}
        candidates = {"feature_contract": preflight.FEATURE_CONTRACT, "separation_contract": preflight.SEPARATION_CONTRACT,
                      "diagnostic_window_ms": 1024, "sample_rate_num": 78125, "sample_rate_den": 2,
                      "shaft_millihz": 25000, "shaft_confirmed": 1, "model_validated": 1, "model_version": 12,
                      "geometry_confirmed": 1, "calibration_version": 77, "target_mode": "fault",
                      "sequence": index + 1, "result_age_ms": 200, "snapshot_epoch": 4,
                      "snapshot_first_sample": first, "candidates": [candidate],
                      "separation": {"invalid_input": 0, "ready_mask": 1, "max_weight_norm": 4,
                                     "carrier_bins": 63, "carrier_usable_bins": 63, "carrier_max_gap": 0,
                                     "target_error": 1e-12, "max_null_leakage": .001,
                                     "min_sector_gain": .9, "max_sector_gain": 1.1, "max_sector_leakage": .01,
                                     "usable_mask": [0xffffffff]*6 + [1023]}}
        scores = [0]*1024
        scores[528] = 1000
        heatmap = {"scan_model": "far_field_direction", "width": 32, "scores": scores, "sequence": 2 + index*2,
                   "map_age_us": 9900, "stale_after_us": 13377, "reason": 0}
        rounds.append({"started_at": STAMP, "responses": {name: {"http_status": 200, "data": value} for name, value in
                      (("status", status), ("gsc", gsc), ("candidates", candidates), ("heatmap", heatmap))}})
    evidence = {"schema": 1, "collected_at": STAMP, "completed_at": STAMP, "rounds": rounds, "fixture_only": True}
    review = preflight.review_template()
    review.update(board_id="SYNTHETIC_FIXTURE", review_id="OFFLINE_TEST", reviewed_at=STAMP)
    review["electrical"].update(measured_supply_volts=3.3, measured_clock_hz=2500000,
                                measured_clock_duty_percent=50, data5_independent_verified=True, fpga_header_wiring_checked=True)
    review["deployment"].update(loaded_package_verified=True, package_manifest_sha256=package["manifest_sha256"],
                                pl_bit_sha256=package["manifest"]["files"]["pl.bit"]["sha256"],
                                ps_elf_sha256=package["manifest"]["files"]["ps_ui.elf"]["sha256"])
    review["localization"].update(channel_mapping_verified=True, sound_hole_coordinates_verified=True,
                                  amplitude_phase_calibration_verified=True, calibration_version=77, calibration_review_id="FIXTURE_CAL")
    review["diagnosis"].update(model_version=12, model_validation_review_id="FIXTURE_MODEL", rpm=1500, rpm_source="fixture_tachometer")
    return evidence, review


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="c9_preflight_")
        self.addCleanup(self.temp.cleanup)
        self.package = fixture_package(self.temp.name)
        self.evidence, self.review = fixtures(self.package)

    def run_check(self, *, live=True):
        return preflight.evaluate(self.package, self.evidence, self.review, now=NOW, live=live)

    def latest(self, endpoint):
        return self.evidence["rounds"][-1]["responses"][endpoint]["data"]

    def assert_stage(self, report, stage, ready):
        self.assertEqual(report["stages"][stage]["ready_now"], ready, report["stages"])

    def test_valid_staged_evidence(self):
        report = self.run_check()
        for stage in preflight.STAGES:
            self.assert_stage(report, stage, True)
        self.assertFalse(report["board_acceptance"])

    def test_offline_cannot_qualify_live_board(self):
        report = self.run_check(live=False)
        self.assertEqual(report["recorded_evidence_level"], "fault-diagnosis-ready")
        self.assertEqual(report["controlled_test_level"], "blocked")
        for stage in preflight.STAGES:
            self.assert_stage(report, stage, False)

    def test_unreviewed_capture_is_not_promoted(self):
        self.review = {}
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_calibration_capture_does_not_require_model_or_geometry(self):
        self.package["manifest"].update(physical_geometry_confirmed=False, classifier_validated=False, model_version=0, model_review_id="")
        self.package["config"]["physical_mapping_confirmed"] = False
        self.review["localization"] = {}
        self.review["diagnosis"] = {}
        for round_ in self.evidence["rounds"]:
            round_["responses"]["gsc"]["data"].update(geometry_confirmed=0, calibration_version=0, calibration_status="unmeasured")
            state = round_["responses"]["candidates"]["data"]
            state.update(geometry_confirmed=0, calibration_version=0, model_version=0, model_validated=0, shaft_confirmed=0)
            state["candidates"][0]["diagnosis"].update(label="unknown", model_validated=0, model_version=0)
        report = self.run_check()
        self.assert_stage(report, "capture-ready", True)
        self.assert_stage(report, "localization-ready", False)
        self.assert_stage(report, "fault-diagnosis-ready", False)

    def test_missing_runtime_field_rejected(self):
        for field in ("localizer_abi", "rv32_itcm_sha256", "window_samples", "active_mask", "sample_rate_num"):
            evidence = copy.deepcopy(self.evidence)
            del self.latest("gsc")[field]
            self.assert_stage(self.run_check(), "capture-ready", False)
            self.evidence = evidence

    def test_old_S2_frontend_cannot_be_relabelled_as_S3(self):
        self.package["manifest"]["separation_contract"] = "C9S2"
        self.assert_stage(self.run_check(), "capture-ready", False)
        self.package["manifest"]["separation_contract"] = "C9S3"
        self.latest("candidates")["separation_contract"] = 0x43395332
        self.assert_stage(self.run_check(), "fault-diagnosis-ready", False)

    def test_mismatched_abi_rate_and_geometry_rejected(self):
        for field, bad in (("localizer_abi", "P8O1"), ("sample_rate_num", 390625), ("geometry_version", 123),
                           ("rv32_itcm_sha256", "0"*64), ("capture_slots", 9)):
            evidence = copy.deepcopy(self.evidence)
            self.latest("gsc")[field] = bad
            self.assert_stage(self.run_check(), "capture-ready", False)
            self.evidence = evidence

    def test_stale_snapshot_rejected(self):
        self.evidence["completed_at"] = datetime.fromtimestamp(NOW - 301, timezone.utc).isoformat()
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_missing_endpoint_rejected(self):
        self.evidence["rounds"][-1]["responses"].pop("gsc")
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_updating_map_is_not_localization_ready(self):
        self.evidence["rounds"][-1]["responses"]["heatmap"] = {"http_status": 202, "data": {"state": "updating"}}
        report = self.run_check()
        self.assert_stage(report, "capture-ready", True)
        self.assert_stage(report, "localization-ready", False)

    def test_silence_and_saturation_rejected(self):
        for field, value in (("mic_rms_ppm", [0]*9), ("mic_clipped", [1]*9), ("mic_peak_ppm", [1000000]*9)):
            evidence = copy.deepcopy(self.evidence)
            self.latest("status")[field] = value
            self.assert_stage(self.run_check(), "capture-ready", False)
            self.evidence = evidence

    def test_all_nine_channels_required(self):
        self.latest("status")["mic_rms_ppm"] = [1000]*8
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_replay_and_stalled_capture_rejected(self):
        self.latest("status")["input_mode"] = 1
        self.assert_stage(self.run_check(), "capture-ready", False)
        self.latest("status")["input_mode"] = 2
        self.latest("status")["mic_seq"] = 4
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_incrementing_drops_rejected(self):
        self.latest("gsc")["dma_drops"] = 1
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_counter_wrap_is_valid_progress(self):
        for index, round_ in enumerate(self.evidence["rounds"]):
            round_["responses"]["status"]["data"]["received_blocks"] = [0xfffffffe, 0xffffffff, 0][index]
            round_["responses"]["status"]["data"]["mic_seq"] = [0xfffffffc, 0xfffffffe, 2][index]
        self.assert_stage(self.run_check(), "capture-ready", True)

    def test_nominal_voltage_is_not_measured_voltage(self):
        self.review["electrical"]["measured_supply_volts"] = None
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_brand_or_pin_activity_cannot_replace_electrical_review(self):
        self.review["electrical"]["microphone_chip_model"] = "Infineon"
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_clock_waveform_needs_measurement(self):
        self.review["electrical"]["measured_clock_duty_percent"] = 70
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_configuration_file_hash_is_not_physical_calibration(self):
        self.latest("gsc")["calibration_status"] = "unmeasured"
        report = self.run_check()
        self.assert_stage(report, "capture-ready", True)
        self.assert_stage(report, "localization-ready", False)

    def test_latency_limit_is_separate_from_capture(self):
        self.latest("gsc")["pcm_to_ps_max_us"] = 10100
        report = self.run_check()
        self.assert_stage(report, "capture-ready", True)
        self.assert_stage(report, "localization-ready", False)

    def test_old_fault_direction_is_rejected(self):
        state = self.latest("candidates")
        state["result_age_ms"] = 3000
        state["candidates"][0]["diagnosis"].update(label="fault", fault_direction_valid=1)
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_mismatched_snapshot_binding_rejected(self):
        self.latest("candidates")["candidates"][0]["diagnosis"]["binding"]["track_id"] = 7
        report = self.run_check()
        self.assert_stage(report, "localization-ready", True)
        self.assert_stage(report, "fault-diagnosis-ready", False)

    def test_baseline_model_is_not_fault_model(self):
        self.latest("candidates")["candidates"][0]["diagnosis"]["model_kind"] = 1
        self.assert_stage(self.run_check(), "fault-diagnosis-ready", False)

    def test_model_version_must_match_package_runtime_and_review(self):
        for source in ("package", "runtime", "review"):
            manifest, evidence, review = copy.deepcopy(self.package["manifest"]), copy.deepcopy(self.evidence), copy.deepcopy(self.review)
            if source == "package":
                self.package["manifest"]["model_version"] = 13
            elif source == "runtime":
                self.latest("candidates")["model_version"] = 13
            else:
                self.review["diagnosis"]["model_version"] = 13
            report = self.run_check()
            self.assert_stage(report, "capture-ready", True)
            self.assert_stage(report, "fault-diagnosis-ready", False)
            self.package["manifest"], self.evidence, self.review = manifest, evidence, review

    def test_review_id_must_match_exact_packaged_model_review(self):
        for other_review in ("DIFFERENT_REAL_MODEL_REVIEW", "", " FIXTURE_MODEL "):
            self.review["diagnosis"]["model_validation_review_id"] = other_review
            report = self.run_check()
            self.assert_stage(report, "capture-ready", True)
            self.assert_stage(report, "fault-diagnosis-ready", False)

    def test_missing_package_model_identity_cannot_borrow_runtime_model(self):
        for field in ("model_version", "model_review_id"):
            manifest = copy.deepcopy(self.package["manifest"])
            del self.package["manifest"][field]
            self.assert_stage(self.run_check(), "fault-diagnosis-ready", False)
            self.package["manifest"] = manifest

    def test_model_artifacts_must_be_in_the_hashed_package(self):
        for name in ("diagnostic_model.h", "diagnostic_model.json"):
            manifest = copy.deepcopy(self.package["manifest"])
            del self.package["manifest"]["files"][name]
            report = self.run_check()
            self.assert_stage(report, "capture-ready", True)
            self.assert_stage(report, "fault-diagnosis-ready", False)
            self.package["manifest"] = manifest

    def test_tampered_packaged_model_is_rejected(self):
        (Path(self.temp.name) / "diagnostic_model.json").write_text('{"wrong_model":true}')
        self.package = preflight.inspect_package(self.temp.name)
        self.assert_stage(self.run_check(), "fault-diagnosis-ready", False)
        self.assertTrue(any("diagnostic_model.json" in item for item in self.package["issues"]))

    def test_default_no_model_allows_capture_but_withholds_diagnosis(self):
        self.package["manifest"].update(classifier_validated=False, model_version=0, model_review_id="")
        self.review["diagnosis"].update(model_version=0, model_validation_review_id="")
        for round_ in self.evidence["rounds"]:
            state = round_["responses"]["candidates"]["data"]
            state.update(model_version=0, model_validated=0)
            state["candidates"][0]["diagnosis"].update(model_version=0, model_validated=0, model_kind=0, label="unknown")
        report = self.run_check()
        self.assert_stage(report, "capture-ready", True)
        self.assert_stage(report, "localization-ready", True)
        self.assert_stage(report, "fault-diagnosis-ready", False)

    def test_rpm_must_match_review(self):
        self.review["diagnosis"]["rpm"] = 1200
        self.assert_stage(self.run_check(), "fault-diagnosis-ready", False)

    def test_no_carrier_cannot_be_diagnostic_ready(self):
        self.latest("candidates")["candidates"][0]["diagnosis"]["extraction"]["status"] = 4
        self.assert_stage(self.run_check(), "fault-diagnosis-ready", False)

    def test_unsafe_mask_cannot_be_hidden_by_reported_coverage(self):
        self.latest("candidates")["separation"]["usable_mask"][1] = 0
        self.assert_stage(self.run_check(), "fault-diagnosis-ready", False)

    def test_unvalidated_fault_claim_is_error(self):
        state = self.latest("candidates")
        state["model_validated"] = 0
        state["candidates"][0]["diagnosis"].update(label="fault", fault_direction_valid=1)
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_active_gsc_without_eligible_fault_is_error_in_fault_mode(self):
        for round_ in self.evidence["rounds"]:
            round_["responses"]["gsc"]["data"]["gsc_reason"] = 0
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_single_cross_endpoint_target_transition_is_reported_for_repeat(self):
        self.latest("gsc")["gsc_reason"] = 0
        report = self.run_check()
        self.assert_stage(report, "capture-ready", True)
        self.assertTrue(any("One fault-target" in note for note in report["notes"]))

    def test_genuine_eligible_fault_binding_is_reported(self):
        self.latest("gsc")["gsc_reason"] = 0
        self.latest("candidates")["candidates"][0]["diagnosis"].update(label="fault", fault_direction_valid=1)
        report = self.run_check()
        self.assert_stage(report, "fault-diagnosis-ready", True)
        self.assertEqual(report["observed_fault_directions"][0]["track_id"], 3)

    def test_tampered_package_rejected(self):
        (Path(self.temp.name) / "ps_ui.elf").write_bytes(b"wrong ELF")
        self.package = preflight.inspect_package(self.temp.name)
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_missing_or_invalid_manifest_reports_blockers_without_crash(self):
        path = Path(self.temp.name) / "manifest.json"
        path.write_text("[]")
        self.package = preflight.inspect_package(self.temp.name)
        self.assert_stage(self.run_check(), "capture-ready", False)
        path.unlink()
        self.package = preflight.inspect_package(self.temp.name)
        self.assert_stage(self.run_check(), "capture-ready", False)

    def test_manifest_path_traversal_rejected(self):
        path = Path(self.temp.name) / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["files"]["../outside"] = {"sha256": "0"*64, "bytes": 0}
        path.write_text(json.dumps(manifest))
        self.assertTrue(any("escapes" in e for e in preflight.inspect_package(self.temp.name)["issues"]))

    def test_duplicate_and_nonfinite_json_rejected(self):
        for data in ('{"key":1,"key":2}', '{"value":NaN}'):
            with self.assertRaises(ValueError):
                preflight.strict_json(data)

    def test_collect_only_reads_declared_endpoints(self):
        calls = []
        payloads = self.evidence["rounds"][0]["responses"]
        class Response(io.BytesIO):
            status = 200
            headers = {"Content-Type": "application/json"}
        def fetch(request, timeout):
            calls.append((request.get_method(), request.full_url))
            return Response(json.dumps(payloads[request.full_url.rsplit("/", 1)[1]]["data"]).encode())
        with patch.object(preflight.urllib.request, "urlopen", fetch), patch.object(preflight.time, "sleep"):
            observed = preflight.collect("http://fixture-board", 2, .01, 1)
        self.assertEqual(len(observed["rounds"]), 2)
        self.assertEqual(len(calls), 8)
        self.assertTrue(all(method == "GET" and url.rsplit("/", 1)[1] in preflight.ENDPOINTS for method, url in calls))

    def test_offline_cli_report_retains_evidence_and_never_returns_live_pass(self):
        evidence_path = Path(self.temp.name) / "http.json"
        review_path = Path(self.temp.name) / "review.json"
        output = Path(self.temp.name) / "report.json"
        evidence_path.write_text(json.dumps(self.evidence))
        review_path.write_text(json.dumps(self.review))
        result = subprocess.run([sys.executable, str(ROOT/"pc/circular9_preflight.py"), "--package", self.temp.name,
            "--offline", str(evidence_path), "--review", str(review_path), "--output", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        report = preflight.read_json(output)
        self.assertFalse(report["live_probe"])
        self.assertEqual(report["controlled_test_level"], "blocked")
        self.assertIn("http_evidence", report)

    def make_recording(self, *, gap=False, corrupt=False, flat=False, clipped=False):
        directory = Path(self.temp.name) / "recording"
        directory.mkdir()
        payloads = []
        geometry = self.latest("gsc")["geometry_version"]
        for packet in range(128):
            header = [0x32433943, 2, 64, 123, packet, 8, 0x000a0009, 511, 156250, 1, 40000000, geometry, 77, 0, 0, 1]
            data = bytearray(struct.pack("<16I", *header))
            for index in range(8):
                sample = packet*8 + index
                sequence = sample + (1 if gap and sample >= 500 else 0)
                slot = [0]*32
                slot[:8] = [0x47534302, sequence, 1, 0, 1, 65536, 1, 123 | (122 << 16)]
                for ch in range(9):
                    value = 123 if flat else sample % 100 - 50 + ch
                    if clipped and sample == 100 and ch == 8:
                        value = 32767
                    slot[8 + ch//2] |= (value & 65535) << (16*(ch & 1))
                slot[13:24] = [0x000a0009, 4, 0, sample*256, 0, sample, 0, 0x394d4450, 128, 77, 0x00100009]
                slot[30] = zlib.crc32(struct.pack("<30I", *slot[:30]))
                slot[31] = ~sample & 0xffffffff
                data += struct.pack("<32IhH", *slot, 122, 1)
            data += struct.pack("<I", zlib.crc32(data))
            payloads.append(struct.pack("<I", len(data)) + data)
        content = bytearray(b"".join(payloads))
        if corrupt:
            content[100] ^= 1
        (directory / "packets.c9").write_bytes(content)
        (directory / "manifest.json").write_text(json.dumps({"raw_channels": 9, "sample_rate_num": 156250, "sample_rate_den": 1,
                                                             "invalid_packets": 0, "samples": 1024}))
        return directory

    def test_original_packet_recording_is_rechecked(self):
        recording = preflight.inspect_recording(self.make_recording())
        self.assertTrue(recording["passed"], recording)
        self.assertEqual(recording["samples"], 1024)
        report = preflight.evaluate(self.package, self.evidence, self.review, recording, now=NOW, live=True)
        self.assert_stage(report, "capture-ready", True)

    def test_original_recording_crc_corruption_rejected(self):
        self.assertFalse(preflight.inspect_recording(self.make_recording(corrupt=True))["passed"])

    def test_original_recording_sample_gap_rejected(self):
        self.assertFalse(preflight.inspect_recording(self.make_recording(gap=True))["passed"])

    def test_original_recording_constant_channel_rejected(self):
        self.assertFalse(preflight.inspect_recording(self.make_recording(flat=True))["passed"])

    def test_original_recording_clipping_rejected(self):
        self.assertFalse(preflight.inspect_recording(self.make_recording(clipped=True))["passed"])


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PreflightTests)
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    log = stream.getvalue()
    print(log)
    (OUT / "native.log").write_text(log, encoding="utf-8")
    evidence = {"passed": result.wasSuccessful(), "tests": result.testsRun, "hardware_tested": False,
                "fixture": "Synthetic package bytes/operator reviews/HTTP snapshots only; not hardware qualification",
                "sources": {name: preflight.digest(ROOT/name) for name in
                            ("pc/circular9_preflight.py", "scripts/check_circular9_preflight.py", "pc/circular9_receive.py", "pc/circular9_capture.py")}}
    (OUT / "results.json").write_text(json.dumps(evidence, indent=2) + "\n")
    if not result.wasSuccessful():
        raise SystemExit(1)
    print("CIRCULAR9_PREFLIGHT_TESTS_PASS tests=" + str(result.testsRun) + " hardware=UNVERIFIED")
