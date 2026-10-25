#!/usr/bin/env python3
"""Focused contract, rejection, model-training and C implementation checks."""
import importlib.util
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import copy
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("c9dataset", ROOT / "pc/circular9_dataset.py")
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


def must_reject(fn):
    try:
        fn()
    except ValueError:
        return
    raise AssertionError("invalid dataset accepted")


def fixture(prefix):
    rows = []
    for label, center in (("normal", 0), ("fault", 10), ("interference", -10)):
        for k in range(6):
            rows.append({"feature_contract": tool.CONTRACT, "label": label,
                         "recording_id": f"{prefix}_{label}_{k//3}",
                         "features": [center + (k % 3 - 1) * 0.1] * 18,
                         "shaft_hz": 25, "rms": 0.1,
                         "extraction": {"status": 1},
                         "separation_contract": tool.SEPARATION_CONTRACT,
                         "separation_usable_mask": [0xffffffff] * 6 + [1023],
                         "binding": {"track_id": 1, "epoch": 3,
                                     "first_sample": k * 200000, "sample_count": 40000, "flags": 15}})
    return rows


def main():
    train, holdout = fixture("train"), fixture("holdout")
    model = tool.fit(train, version=22)
    assert model["validated"] == 0
    for row in holdout:
        assert tool.predict(model, row["features"]) == tool.LABELS[row["label"]]
    evidence = tool.validate(model, train, holdout)
    assert all(m["precision"] == m["recall"] == 1 and m["recordings"] == 2 for m in evidence["classes"])
    must_reject(lambda: tool.validate(model, train, train))
    unseen = fixture("unseen")
    unseen[0]["separation_usable_mask"][0] ^= 1
    assert tool.validate(model, train, unseen)["unseen_filter_segments"] == 1
    must_reject(lambda: tool.fit(train[:2], version=1))
    normal = [r for r in train if r["label"] == "normal"]
    baseline = tool.fit(normal, baseline=True, version=3)
    assert tool.predict(baseline, [10] * 18) == 4  # anomaly, never fault
    must_reject(lambda: tool.fit(train, baseline=True))
    old = copy.deepcopy(train)
    old[0]["feature_contract"] = 0x43394631
    must_reject(lambda: tool.fit(old))
    old_model = dict(model, feature_contract=0x43394631)
    must_reject(lambda: tool.predict(old_model, [0]*18))
    must_reject(lambda: tool.export_header(old_model))
    must_reject(lambda: tool.validate(model, train, old))
    old_separation = copy.deepcopy(train)
    old_separation[0]["separation_contract"] = 0x43395332
    must_reject(lambda: tool.fit(old_separation))
    must_reject(lambda: tool.predict(dict(model,separation_contract=0x43395332), [0]*18))
    pcm = b"\x00\x00" * 40000
    mode = ["ok"]
    class AudioFixture(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            offset, count = int(q["offset"][0]), int(q["count"][0])
            if q["sequence"] != ["17"] or mode[0] == "expired" and offset >= 512:
                self.send_error(409); return
            assert count <= 512
            data = pcm[2*offset:2*(offset+count)]
            if mode[0] == "short":
                data = data[:-1]
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)));self.end_headers();self.wfile.write(data)
    server = ThreadingHTTPServer(("127.0.0.1", 0), AudioFixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True);thread.start()
    try:
        url = "http://127.0.0.1:%d" % server.server_port
        assert tool.fetch_candidate_audio(url, 17, 0) == pcm
        mode[0] = "short";must_reject(lambda: tool.fetch_candidate_audio(url, 17, 0))
        mode[0] = "expired"
        try:
            tool.fetch_candidate_audio(url, 17, 0)
        except urllib.error.HTTPError as err:
            assert err.code == 409
        else:
            raise AssertionError("mixed/expired audio accepted")
    finally:
        server.shutdown();server.server_close();thread.join()
    assert tool.resample_listening_48k(pcm) == b"\x00\x00" * 49152
    with tempfile.TemporaryDirectory() as name:
        folder = Path(name)
        dataset = folder / "train.jsonl"
        validation = folder / "validation.jsonl"
        def write(path, rows):
            path.write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
        write(dataset, train); write(validation, holdout)
        assert len(tool.read_rows(dataset)) == 18
        write(dataset, train + train[:1]); must_reject(lambda: tool.read_rows(dataset))
        broken = fixture("broken"); broken[0]["binding"]["flags"] = 7
        write(dataset, broken); must_reject(lambda: tool.read_rows(dataset))
        broken = fixture("no_carrier"); broken[0]["extraction"]["status"] = 2
        write(dataset, broken); must_reject(lambda: tool.read_rows(dataset))
        write(dataset, old); must_reject(lambda: tool.read_rows(dataset))
        write(dataset, train)
        output = folder / "fixture_unvalidated.json"
        tool.main(["fit", "--train", str(dataset), "--validation", str(validation),
                   "--version", "22", "--output", str(output)])
        assert json.loads(output.read_text())["status"] == "UNVALIDATED"
        assert ".validated=0u" in output.with_suffix(".h").read_text()
        must_reject(lambda: tool.main(["fit", "--train", str(dataset), "--version", "23",
                                      "--review-id", "INVALID_WITHOUT_HOLDOUT", "--output", str(folder / "no.json")]))
        gcc = shutil.which("gcc")
        if not gcc:
            raise RuntimeError("GCC required")
        exe = folder / "diagnosis.exe"
        subprocess.run([gcc, "-std=c99", "-O2", "-Isw", "-Isw/cstub",
                        "sw/circular9_diagnosis.c", "sw/circular9_diagnosis_test.c", "-lm", "-o", str(exe)],
                       cwd=ROOT, check=True)
        subprocess.run([str(exe)], cwd=ROOT, check=True)
        # Generated model header must compile through the actual explicit production hook.
        configured_source = folder / "configured.c"
        configured_source.write_text('''#include "circular9_diagnosis.h"
#include <assert.h>
int main(void){
 const c9_diag_model *m=c9_diag_configured_model();
 assert(m->version==22 && m->abi==2 && !m->validated && m->mask_count==1);
 c9_diag_binding b={1,10,1,100,40000,15,0,0};
 b.separation_contract=C9_DIAG_SEPARATION_CONTRACT;
 for(unsigned j=0;j<7;j++)b.usable_mask[j]=j<6?0xffffffffu:1023u;
 double v[18];for(unsigned i=0;i<18;i++)v[i]=10;
 c9_diag_report r;c9_diag_score_features(v,.1,25,&b,m,&r);
 assert(r.provisional_label==C9_DIAG_FAULT && r.label==C9_DIAG_UNKNOWN);
 b.usable_mask[0]^=1;c9_diag_score_features(v,.1,25,&b,m,&r);
 assert(r.reason==C9_DIAG_BAD_FILTER && !r.fault_direction_valid);
 return 0;
}''', encoding="utf-8")
        configured_exe = folder / "configured.exe"
        subprocess.run([gcc, "-std=c99", "-O2", "-Isw", "-Isw/cstub",
                        f'-DC9_DIAG_MODEL_HEADER="{output.with_suffix(".h").as_posix()}"',
                        "sw/circular9_diagnosis.c", str(configured_source), "-lm", "-o", str(configured_exe)], cwd=ROOT, check=True)
        subprocess.run([str(configured_exe)], cwd=ROOT, check=True)
    result = {"passed": True, "evidence_scope": "synthetic_contract_fixtures_only",
              "real_machine_model_validated": False, "feature_contract": tool.CONTRACT,
              "separation_contract": tool.SEPARATION_CONTRACT, "model_abi": 2,
              "checks": ["binding_and_unknown_guards", "three_class_scores", "baseline_never_fault",
                         "unseen_separation_mask_rejected", "independent_recording_split",
                         "generated_header_runtime", "snapshot_audio_expiry", "listening_wav_duration",
                         "legacy_feature_contract_rejected", "full_record_extraction_metadata"],
              "source_sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                for name in ("sw/circular9_diagnosis.c", "sw/circular9_diagnosis.h",
                                             "pc/circular9_dataset.py", "sw/circular9_diagnosis_test.c",
                                             "sw/circular9_envelope.h")}}
    artifact = ROOT / "build/circular9_diagnosis_checks/results.json"
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("CIRCULAR9_DATASET_PASS synthetic_fixtures_only no_real_model_created")


if __name__ == "__main__":
    main()
