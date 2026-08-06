#!/usr/bin/env python3
"""Idempotent verifier for the E02 frozen baseline."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {"verification.json", "verification.sha256", "idempotence-proof.json"}


def canon(value): return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()
def sha(data): return hashlib.sha256(data).hexdigest()


def main():
    checks = []
    result = json.loads((ROOT / "result.json").read_bytes())
    capture = json.loads((ROOT / "outputs/capture-manifest.json").read_bytes())
    score = json.loads((ROOT / "outputs/threshold-scorecard.json").read_bytes())
    fixtures = json.loads((ROOT / "fixture-manifest.json").read_bytes())
    checks.append({"id": "assignment", "pass": result["assignment_id"] == "experiment-02" and result["round"] == 1})
    checks.append({"id": "inventory_digest", "pass": result["inventory_digest"] == "3e480a9fcf44da65a07aa1fcad8e981911006568d23b89ad8891f26a5d96e69e"})
    checks.append({"id": "exact_papers", "pass": [(p["short_id"], p["expected_rev"]) for p in capture["papers"]] == [("CCH29", "18768b0a14c2eead927181c4a0e37c18"), ("PDS45", "b992fd8aaa028b0dab30a8da76f077fd"), ("CCH28", "49c1534d9fb76d0d9adc7b97f25ec471"), ("PDS44", "8bbd5d874a1b697f1e4e437c473f8e52")]})
    checks.append({"id": "pins_and_projection", "pass": all(p["pin_match"] and p["projection_match"] for p in capture["papers"])})
    checks.append({"id": "browser_denominators", "pass": sum(len(p["browser"][s]) for p in capture["papers"] for s in ("public", "email")) == 16})
    checks.append({"id": "browser_widths", "pass": all(set(p["browser"][s]) == {"320", "390"} for p in capture["papers"] for s in ("public", "email"))})
    checks.append({"id": "fixture_hashes", "pass": all(sha((ROOT / f["path"]).read_bytes()) == f["sha256"] for f in fixtures["fixtures"])})
    checks.append({"id": "fixture_manifest_hash", "pass": sha((ROOT / "fixture-manifest.json").read_bytes()) == result["fixture_manifest_sha256"]})
    checks.append({"id": "hard_statuses", "pass": score["summary"]["FAIL"] > 0 and score["summary"]["BLOCKED"] > 0 and result["verdict"] == "BASELINE_FAIL_WITH_BLOCKED_SURFACES"})
    checks.append({"id": "no_candidate", "pass": result["candidate_ids"] == []})
    checks.append({"id": "blocked_not_proxy_pass", "pass": all(g["status"] == "BLOCKED" and g["passed"] == 0 for g in score["gates"] if g["id"] in {"authenticated_studio", "real_assistive_technology", "real_mail_clients", "adversarial_reader_execution"})})
    evidence = {}
    for path in sorted(p for p in ROOT.rglob("*") if p.is_file() and p.name not in EXCLUDED and "tmp" not in p.relative_to(ROOT).parts):
        evidence[str(path.relative_to(ROOT))] = sha(path.read_bytes())
    payload = {"schema_version": "legendary-e02-verification/v1", "verdict": "PASS" if all(c["pass"] for c in checks) else "FAIL", "checks": checks, "evidence_file_count": len(evidence), "evidence_hashes": evidence}
    data = canon(payload) + b"\n"
    (ROOT / "verification.json").write_bytes(data)
    digest = sha(data)
    (ROOT / "verification.sha256").write_text(digest + "\n")
    print(json.dumps({"verdict": payload["verdict"], "verification_sha256": digest, "checks_passed": sum(c["pass"] for c in checks), "checks_total": len(checks), "evidence_files": len(evidence)}, sort_keys=True))
    raise SystemExit(0 if payload["verdict"] == "PASS" else 1)


if __name__ == "__main__": main()
