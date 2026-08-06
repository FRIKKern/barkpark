#!/usr/bin/env python3
"""Run the pure verifier twice and persist byte-identity plus elapsed timing."""
import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "scripts" / "verify.py"
rows = []
outputs = []
for run in (1, 2):
    started = time.perf_counter()
    proc = subprocess.run(["python3", str(VERIFY)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    elapsed = round(time.perf_counter() - started, 6)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.decode("utf-8", "replace"))
    output = proc.stdout
    outputs.append(output)
    path = ROOT / "reports" / f"verification-run-{run}.json"
    path.write_bytes(output)
    rows.append({"run": run, "status": "PASS", "seconds": elapsed, "bytes": len(output), "sha256": hashlib.sha256(output).hexdigest(),
                 "artifact_set_sha256": json.loads(output)["artifact_set_sha256"]})
summary = {"schema_version": "restart-e03-replay-summary/v1", "runs": rows, "byte_identical": outputs[0] == outputs[1],
           "output_sha256_identical": rows[0]["sha256"] == rows[1]["sha256"],
           "artifact_set_sha256_identical": rows[0]["artifact_set_sha256"] == rows[1]["artifact_set_sha256"]}
(ROOT / "reports" / "replay-summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
