#!/usr/bin/env python3
"""Record PS separated-source features and fit an explicit C9F2 diagnostic artifact.

No audio labels are inferred. Normal-baseline anomaly does not mean bearing fault.
An exported model remains unvalidated unless independent recording-level validation
meets the requested per-class precision/recall and the operator supplies a review ID.
Only use labels confirmed by independent source recordings or equipment inspection.
"""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import statistics
import sys
import time
import urllib.error
import urllib.request
import wave

CONTRACT = 0x43394632
SEPARATION_CONTRACT = 0x43395333
LABELS = {"normal": 1, "fault": 2, "interference": 3}
FEATURE_PIPELINE = {"observation_seconds": 1.024, "carrier_low_hz": 2200,
                    "carrier_high_hz": 4600, "carrier_transition_guard_hz": 400,
                    "carrier_guarded_core_low_hz": 2600, "carrier_guarded_core_high_hz": 4200,
                    "carrier_band_validation": "engineering_choice_real_recordings_required",
                    "analytic_fir_taps": 257, "analytic_decimation": 4,
                    "envelope_antialias_fir_taps": 129, "envelope_antialias_cutoff_hz": 900,
                    "envelope_decimation": 4, "envelope_samples": 2500,
                    "envelope_rate_hz": 2441.40625, "envelope_fft_size": 4096,
                    "fft_bin_spacing_hz": 0.59604644775390625,
                    "true_record_reciprocal_hz": 0.9765625,
                    "hann_enbw_hz": 1.4654299219687874,
                    "hann_first_null_from_peak_hz": 1.95390656262505,
                    "order_peak_minimum_half_width_hz": 0.9765625,
                    "order_peak_relative_half_width": 0.01,
                    "order_peak_tolerance_validation": "engineering_bound_not_speed_tracking"}


def read_rows(path):
    rows = []
    for lineno, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("feature_contract") != CONTRACT:
            raise ValueError(f"{path}:{lineno}: wrong feature contract")
        if row.get("label") not in LABELS or not row.get("recording_id"):
            raise ValueError(f"{path}:{lineno}: explicit label and recording_id required")
        v = row.get("features", [])
        if len(v) != 18 or any(not isinstance(x, (int, float)) or not math.isfinite(x) for x in v):
            raise ValueError(f"{path}:{lineno}: 18 finite features required")
        hz, rms = row.get("shaft_hz", 0), row.get("rms", 0)
        if not isinstance(hz, (int, float)) or not math.isfinite(hz) or not 10 <= hz <= 30:
            raise ValueError(f"{path}:{lineno}: measured shaft_hz must be 10..30")
        if not isinstance(rms, (int, float)) or not math.isfinite(rms) or rms <= 0:
            raise ValueError(f"{path}:{lineno}: nonzero finite rms required")
        if row.get("clipped_samples", 0) > 40:
            raise ValueError(f"{path}:{lineno}: clipped audio")
        if row.get("extraction", {}).get("status") not in (1, 3):
            raise ValueError(f"{path}:{lineno}: C9F2 carrier extraction required; no-carrier/invalid segments cannot train")
        b = row.get("binding", {})
        if not b.get("track_id") or b.get("sample_count") != 40000 or b.get("flags", 0) & 15 != 15:
            raise ValueError(f"{path}:{lineno}: missing reliable candidate/snapshot binding")
        mask = row.get("separation_usable_mask", [])
        if (row.get("separation_contract") != SEPARATION_CONTRACT or len(mask) != 7 or
                any(not isinstance(v, int) or not 0 <= v <= 0xffffffff for v in mask) or
                not any(mask) or mask[6] > 1023):
            raise ValueError(f"{path}:{lineno}: C9S3 separation contract and 202-bin mask required")
        rows.append(row)
    if not rows:
        raise ValueError("empty dataset")
    keys = [(r["recording_id"], r["binding"].get("epoch"), r["binding"].get("first_sample"),
             r["binding"]["track_id"]) for r in rows]
    if len(set(keys)) != len(keys):
        raise ValueError("duplicate candidate/snapshot in dataset")
    return rows


def predict(model, values):
    if model.get("feature_contract") != CONTRACT or model.get("separation_contract") != SEPARATION_CONTRACT:
        raise ValueError("C9F2/C9S3 model required; legacy artifacts require re-extraction and retraining")
    distances = [sum((values[i] - c[i]) ** 2 * model["inverse_variance"][i]
                     for i in range(18)) / 18 for c in model["center"][:model["classes"]]]
    if model["kind"] == 1:
        return (1 if distances[0] <= model["radius"][0] else
                4 if distances[0] >= model["radius"][0] * model["anomaly_multiplier"] else 0)
    ranking = sorted(range(3), key=lambda c: distances[c])
    best, second = ranking[:2]
    if distances[best] > model["radius"][best] or distances[second] / max(distances[best], 1e-12) < model["minimum_margin"]:
        return 0
    return best + 1


def fit(rows, *, baseline=False, version=1, margin=1.25):
    if not rows or any(r.get("feature_contract") != CONTRACT or
                       r.get("separation_contract") != SEPARATION_CONTRACT or
                       r.get("extraction", {}).get("status") not in (1, 3) for r in rows):
        raise ValueError("C9F2/C9S3 training rows required; legacy rows cannot be relabeled")
    if not 1 <= version <= 0xffffffff or not math.isfinite(margin) or margin <= 1:
        raise ValueError("version positive and margin >1 required")
    groups = [[r for r in rows if LABELS[r["label"]] == c] for c in range(1, 4)]
    count = 1 if baseline else 3
    if baseline and len(rows) != len(groups[0]):
        raise ValueError("baseline training accepts normal recordings only")
    for c in range(count):
        if len(groups[c]) < 3 or len({r["recording_id"] for r in groups[c]}) < 2:
            raise ValueError("each fitted class needs >=3 segments from >=2 independent recordings")
    center = [[statistics.mean(r["features"][i] for r in g) for i in range(18)] if g else [0.0] * 18 for g in groups]
    # Pooled within-class variance, 1 dB^2 floor avoids noise-free overconfidence.
    variance = [max(1.0, sum((r["features"][i] - center[c][i]) ** 2
                            for c in range(count) for r in groups[c]) /
                    max(1, sum(len(g) for g in groups[:count]) - count)) for i in range(18)]
    inv = [1 / x for x in variance]
    radii = [1.0] * 3
    for c in range(count):
        distances = [sum((r["features"][i] - center[c][i]) ** 2 * inv[i]
                         for i in range(18)) / 18 for r in groups[c]]
        radii[c] = max(1.0, max(distances) * 1.5 + 0.5)
    masks = sorted({tuple(r["separation_usable_mask"]) for r in rows})
    if len(masks) > 16:
        raise ValueError("model supports at most 16 explicitly trained separation masks; scope this model's tested direction domain")
    return {"abi": 2, "feature_contract": CONTRACT, "feature_pipeline": FEATURE_PIPELINE, "version": version,
            "kind": 1 if baseline else 2, "classes": count, "validated": 0,
            "shaft_hz_min": min(r["shaft_hz"] for r in rows),
            "shaft_hz_max": max(r["shaft_hz"] for r in rows),
            "rms_min": max(1e-6, min(r["rms"] for r in rows) * 0.25),
            "center": center, "inverse_variance": inv, "radius": radii,
            "minimum_margin": margin, "anomaly_multiplier": 2.0,
            "separation_contract": SEPARATION_CONTRACT, "mask_count": len(masks),
            "allowed_masks": masks}


def validate(model, train, holdout):
    if (model.get("feature_contract") != CONTRACT or model.get("separation_contract") != SEPARATION_CONTRACT or
            any(r.get("feature_contract") != CONTRACT or r.get("separation_contract") != SEPARATION_CONTRACT
                for r in train + holdout)):
        raise ValueError("C9F2/C9S3 validation required; legacy features cannot validate this pipeline")
    if {r["recording_id"] for r in train} & {r["recording_id"] for r in holdout}:
        raise ValueError("train/validation recording_id overlap: split by original recording, never by overlapping windows")
    if any(not model["shaft_hz_min"] <= r["shaft_hz"] <= model["shaft_hz_max"] for r in holdout):
        raise ValueError("validation RPM is outside fitted RPM range; collect training data for that range")
    confusion = [[0] * 5 for _ in range(4)]
    unseen = 0
    for r in holdout:
        mask_ok = tuple(r["separation_usable_mask"]) in model["allowed_masks"]
        if not mask_ok:
            unseen += 1
        prediction = predict(model, r["features"]) if r["rms"] >= model["rms_min"] and mask_ok else 0
        confusion[LABELS[r["label"]]][prediction] += 1
    metrics = []
    for c in range(1, 4 if model["kind"] == 2 else 2):
        actual = sum(confusion[c])
        predicted = sum(row[c] for row in confusion)
        recordings = len({r["recording_id"] for r in holdout if LABELS[r["label"]] == c})
        metrics.append({"class": c, "segments": actual, "recordings": recordings,
                        "precision": confusion[c][c] / predicted if predicted else 0,
                        "recall": confusion[c][c] / actual if actual else 0})
    return {"confusion_rows_actual_cols_predicted_0_unknown_4_anomaly": confusion,
            "unseen_filter_segments": unseen, "classes": metrics}


def export_header(model):
    fmt = lambda v: format(v, ".17g")
    vector = lambda values: "{" + ",".join(fmt(v) for v in values) + "}"
    if model.get("feature_contract") != CONTRACT or model.get("separation_contract") != SEPARATION_CONTRACT:
        raise ValueError("C9F2/C9S3 model required; old features/models must be re-extracted and retrained")
    return ("/* Generated from independently labeled separated-source C9F2 features. */\n"
            "#ifndef C9_CONFIGURED_DIAG_MODEL_H\n#define C9_CONFIGURED_DIAG_MODEL_H\n"
            "static const c9_diag_model c9_configured_diag_model = {\n"
            f" .abi=2u,.feature_contract=0x{CONTRACT:08x}u,.version={model['version']}u,"
            f".kind={model['kind']}u,.validated={model['validated']}u,\n"
            f" .shaft_hz_min={fmt(model['shaft_hz_min'])},.shaft_hz_max={fmt(model['shaft_hz_max'])},.rms_min={fmt(model['rms_min'])},\n"
            " .center={" + ",".join(vector(v) for v in model["center"]) + "},\n"
            " .inverse_variance=" + vector(model["inverse_variance"]) + ",\n"
            " .radius=" + vector(model["radius"]) + ",\n"
            f" .minimum_margin={fmt(model['minimum_margin'])},.anomaly_multiplier={fmt(model['anomaly_multiplier'])},\n"
            f" .separation_contract=0x{SEPARATION_CONTRACT:08x}u,.mask_count={model['mask_count']}u,\n"
            " .allowed_masks={" + ",".join("{" + ",".join(str(v) + "u" for v in mask) + "}"
                                           for mask in model["allowed_masks"]) + "}\n"
            "};\n#endif\n")


def collect(args):
    if args.seconds <= 0 or args.interval < 0.1:
        raise ValueError("seconds positive and interval >=0.1s required")
    seen, written, until = set(), 0, time.monotonic() + args.seconds
    with Path(args.output).open("x", encoding="utf-8") as out:
        while time.monotonic() < until:
            with urllib.request.urlopen(args.url, timeout=3) as response:
                state = json.load(response)
            if not state.get("shaft_confirmed"):
                raise ValueError("confirm the actual RPM on PS before collecting diagnostic features")
            candidates = state.get("candidates", state.get("direction_candidates", []))
            for candidate in candidates:
                report = candidate.get("diagnosis", candidate)
                binding = report.get("binding", {})
                if candidate.get("stale") or binding.get("track_id") != args.track:
                    continue
                key = (binding.get("epoch"), binding.get("first_sample"), args.track)
                if key in seen or len(report.get("features", [])) != 18:
                    continue
                row = dict(report, label=args.label, recording_id=args.recording_id)
                row["separation_contract"] = state.get("separation_contract")
                row["separation_usable_mask"] = state.get("separation", {}).get("usable_mask", [])
                row["geometry_confirmed"] = state.get("geometry_confirmed")
                row["calibration_version"] = state.get("calibration_version")
                # Reuse exact training input validation before committing a row.
                if (report.get("feature_contract") != CONTRACT or binding.get("flags", 0) & 15 != 15
                        or binding.get("sample_count") != 40000):
                    continue
                if report.get("clipped_samples", 0) > 40 or report.get("rms", 0) <= 0:
                    continue
                if report.get("extraction", {}).get("status") not in (1, 3):
                    continue
                if row["separation_contract"] != SEPARATION_CONTRACT or len(row["separation_usable_mask"]) != 7:
                    continue
                out.write(json.dumps(row, allow_nan=False) + "\n"); out.flush()
                seen.add(key); written += 1
            time.sleep(args.interval)
    if not written:
        raise ValueError("no accepted feature segments: check track ID, geometry/calibration, separation and actual RPM")
    print(json.dumps({"segments": written, "output": args.output,
                      "label_origin": "operator_confirmed_source", "track_id": args.track}))


def resample_listening_48k(pcm):
    """Integer linear interpolation for listening only; diagnosis keeps original PCM."""
    samples = array.array("h"); samples.frombytes(pcm)
    if sys.byteorder != "little":
        samples.byteswap()
    count = (len(samples) * 96000 + 78124) // 78125
    result = array.array("h")
    for i in range(count):
        index, fraction = divmod(i * 78125, 96000)
        left, right = samples[min(index, len(samples) - 1)], samples[min(index + 1, len(samples) - 1)]
        value = left * (96000 - fraction) + right * fraction
        result.append((value + 48000) // 96000 if value >= 0 else -((-value + 48000) // 96000))
    if sys.byteorder != "little":
        result.byteswap()
    return result.tobytes()


def fetch_candidate_audio(base_url, sequence, index):
    chunks = []
    for offset in range(0, 40000, 512):
        count = min(512, 40000 - offset)
        url = (base_url.rstrip("/") + f"/api/candidate/audio?sequence={sequence}&index={index}"
               f"&offset={offset}&count={count}")
        # A 409/408 aborts the complete export; never mix snapshots or retain partial PCM.
        with urllib.request.urlopen(url, timeout=3) as response:
            data = response.read()
            if response.headers.get_content_type() == "application/json":
                detail = json.loads(data).get("error", "no PCM audio in response")
                raise ValueError("candidate audio unavailable: " + str(detail))
            if response.headers.get_content_type() != "application/octet-stream" or len(data) != 2 * count:
                raise ValueError("candidate PCM response has wrong content type or byte count")
            chunks.append(data)
    return b"".join(chunks)


def export_audio(args):
    target = Path(args.output)
    targets = [target.with_suffix(".pcm"), target.with_suffix(".json")]
    if args.wav48k:
        targets.append(target.with_suffix(".wav"))
    if any(p.exists() for p in targets):
        raise ValueError("output files already exist; choose a new prefix")
    with urllib.request.urlopen(args.base_url.rstrip("/") + "/api/candidates", timeout=3) as response:
        state = json.load(response)
    candidates = state.get("candidates", [])
    if args.index < 0 or args.index >= len(candidates):
        raise ValueError("candidate index is not present")
    candidate = candidates[args.index]
    if candidate.get("stale") or not candidate.get("separation_ready"):
        raise ValueError("candidate has no current separated audio")
    sequence = state["sequence"]
    pcm = fetch_candidate_audio(args.base_url, sequence, args.index)
    metadata = {"encoding": "PCM_S16LE", "channels": 1, "sample_count": 40000,
                "sample_rate_num": 78125, "sample_rate_den": 2, "duration_seconds": 1.024,
                "pcm_sha256": hashlib.sha256(pcm).hexdigest(), "candidate_index": args.index,
                "sequence": sequence, "candidate": candidate,
                "snapshot_session": state.get("snapshot_session"),
                "snapshot_epoch": state.get("snapshot_epoch"),
                "snapshot_first_sample": state.get("snapshot_first_sample"),
                "diagnostic_model_status": ("no_model_audio_for_training_only" if not state.get("model_version") else
                                            "validated_for_reviewed_domain" if state.get("model_validated") else
                                            "unvalidated_no_confirmed_fault_label"),
                "wav48k": "linear_interpolation_listening_only" if args.wav48k else None}
    encoded = json.dumps(metadata, indent=2, allow_nan=False) + "\n"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.with_suffix(".pcm").write_bytes(pcm)
    target.with_suffix(".json").write_text(encoded, encoding="utf-8")
    if args.wav48k:
        with wave.open(str(target.with_suffix(".wav")), "wb") as wav:
            wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(48000)
            wav.writeframes(resample_listening_48k(pcm))
    print(json.dumps({"sequence": sequence, "track_id": candidate.get("track_id"),
                      "sample_count": 40000, "pcm": str(target.with_suffix('.pcm')),
                      "model_status": metadata["diagnostic_model_status"]}))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("collect")
    capture.add_argument("--url", default="http://192.168.2.10/api/candidates")
    capture.add_argument("--track", type=int, required=True)
    capture.add_argument("--label", choices=LABELS, required=True)
    capture.add_argument("--recording-id", required=True)
    capture.add_argument("--seconds", type=float, default=30)
    capture.add_argument("--interval", type=float, default=0.5)
    capture.add_argument("--output", required=True)
    audio = commands.add_parser("audio", help="Export one complete separated PS candidate snapshot")
    audio.add_argument("--base-url", default="http://192.168.2.10")
    audio.add_argument("--index", type=int, required=True, help="Zero-based candidate index from /api/candidates")
    audio.add_argument("--output", required=True, help="Output file prefix; writes .pcm and .json")
    audio.add_argument("--wav48k", action="store_true", help="Also create a 48kHz WAV for listening, never training")
    train = commands.add_parser("fit")
    train.add_argument("--train", required=True)
    train.add_argument("--validation")
    train.add_argument("--baseline", action="store_true")
    train.add_argument("--version", type=int, required=True)
    train.add_argument("--margin", type=float, default=1.25)
    train.add_argument("--min-precision", type=float, default=0.95)
    train.add_argument("--min-recall", type=float, default=0.90)
    train.add_argument("--review-id", help="Real reviewed physical-test report ID; never supply for synthetic fixtures")
    train.add_argument("--output", required=True, help="Output artifact .json (paired .h is generated)")
    args = parser.parse_args(argv)
    if args.command == "collect":
        collect(args); return
    if args.command == "audio":
        export_audio(args); return
    if not 0 < args.min_precision <= 1 or not 0 < args.min_recall <= 1:
        raise ValueError("precision and recall thresholds must be in (0,1]")
    rows = read_rows(args.train)
    model = fit(rows, baseline=args.baseline, version=args.version, margin=args.margin)
    result = {"model": model, "train_sha256": hashlib.sha256(Path(args.train).read_bytes()).hexdigest(),
              "train_source_path": str(Path(args.train).resolve()),
              "train_recordings": sorted({r["recording_id"] for r in rows}),
              "status": "UNVALIDATED", "review_id": args.review_id}
    if args.review_id and not args.validation:
        raise ValueError("review ID cannot replace independent validation recordings")
    if args.validation:
        holdout = read_rows(args.validation)
        evidence = validate(model, rows, holdout)
        result.update(validation=evidence, validation_sha256=hashlib.sha256(Path(args.validation).read_bytes()).hexdigest(),
                      validation_source_path=str(Path(args.validation).resolve()),
                      validation_recordings=sorted({r["recording_id"] for r in holdout}))
        passed = all(m["segments"] >= 3 and m["recordings"] >= 2 and
                     m["precision"] >= args.min_precision and m["recall"] >= args.min_recall
                     for m in evidence["classes"])
        result["validation_passed_requested_limits"] = passed
        result["requested_limits"] = {"precision": args.min_precision, "recall": args.min_recall}
        if args.review_id:
            if not passed:
                raise ValueError("independent validation does not meet limits/minimum independent recordings")
            model["validated"] = 1; result["status"] = "VALIDATED_FOR_REVIEWED_TEST_DOMAIN"
    target = Path(args.output)
    if target.exists() or target.with_suffix(".h").exists():
        raise ValueError("output artifacts already exist; use a new version/path")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    target.with_suffix(".h").write_text(export_header(model), encoding="utf-8", newline="\n")
    print(json.dumps({"status": result["status"], "model": str(target), "header": str(target.with_suffix('.h'))}))


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read()).get("error", error.reason)
        except (ValueError, OSError):
            detail = error.reason
        print(json.dumps({"error": str(detail), "http_status": error.code,
                          "hint": "For expired snapshots retry the entire audio export; inspect /api/candidates for separation/model state."}))
        sys.exit(2)
    except urllib.error.URLError as error:
        print(json.dumps({"error": "board_connection_failed", "detail": str(error.reason)}));sys.exit(2)
    except (ValueError, OSError) as error:
        print(json.dumps({"error": str(error)}));sys.exit(2)
