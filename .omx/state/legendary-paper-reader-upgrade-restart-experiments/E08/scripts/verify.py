#!/usr/bin/env python3
import json
import hashlib
import tarfile
from pathlib import Path

E08 = Path(__file__).resolve().parents[1]
load = lambda p: json.loads((E08 / p).read_text())
assignment = load("assignment.json")
result = load("result.json")
matrix = load("reports/attack-matrix.json")
repro = load("reports/reproducibility.json")
scan = load("reports/credential-scan.json")
assert assignment["assignment_uuid"] == "ef4bc3aa-adbe-487a-813a-87ba2b27e142"
assert result["round"] == "attack"
assert '"round":"attack"' in (E08 / "result.json").read_text()
assert result["candidate_selected"] is False
assert len(result["candidate_outcomes"]) == 3
assert all(x["verdict"] == "REJECT" for x in result["candidate_outcomes"])
assert repro["status"] == "PASS"
assert scan["status"] == "PASS" and not scan["hits"]
assert result["artifact_set_sha256"] == hashlib.sha256((E08 / "evidence.tar.gz").read_bytes()).hexdigest()
assert {r["viewport"] for r in matrix["rows"] if r.get("reader_kind") == "local_headless_chrome"} == {"desktop", "390", "320", "reflow-200"}
assert any(r["surface"] == "studio" and r["status"] == "BLOCKED" for r in matrix["rows"])
assert any(r["surface"] == "assistive_technology" and r["status"] == "BLOCKED" for r in matrix["rows"])
assert any(r["surface"] == "email_mime" for r in matrix["rows"])
with tarfile.open(E08 / "evidence.tar.gz", "r:gz") as tf:
    names = set(tf.getnames())
assert "result.json" in names and "reports/attack-matrix.json" in names
print("E08 VERIFY PASS")
