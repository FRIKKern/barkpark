#!/usr/bin/env python3
"""Deterministic fail-closed verifier for restart Experiment E02."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERATED = {"verification.json", "verification.sha256", "token-scan.json", "artifact-hashes.json", "replay-proof.json"}
TOKEN_PATTERNS = {
    "authorization_value": re.compile(rb"(?i)authorization[\"' ]{0,3}[:=][\"' ]{0,3}(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]{12,}"),
    "cookie_value": re.compile(rb"_barkpark_key=[A-Za-z0-9._~-]{20,}"),
    "github_token": re.compile(rb"(?:ghp|github_pat)_[A-Za-z0-9_]{20,}"),
    "openai_token": re.compile(rb"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"),
    "jwt": re.compile(rb"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"),
}


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check(check_id, passed, observation):
    return {"id": check_id, "pass": bool(passed), "observation": observation}


def main():
    assignment = json.loads((ROOT / "assignment.json").read_bytes())
    result = json.loads((ROOT / "result.json").read_bytes())
    capture = json.loads((ROOT / "outputs/raw-capture-manifest.json").read_bytes())
    redacted = json.loads((ROOT / "outputs/redacted-capture-manifest.json").read_bytes())
    score = json.loads((ROOT / "outputs/scorecard.json").read_bytes())
    denominators = json.loads((ROOT / "outputs/source-denominators.json").read_bytes())
    handoff_bytes = (ROOT / "cycle-handoff.json").read_bytes()
    handoff = json.loads(handoff_bytes)
    mutation = json.loads((ROOT / "mutation-proof.json").read_bytes())
    evidence = {}
    token_findings = []
    for path in sorted(item for item in ROOT.rglob("*") if item.is_file() and item.name not in GENERATED):
        relative = str(path.relative_to(ROOT))
        data = path.read_bytes()
        evidence[relative] = sha(data)
        for pattern_id, pattern in TOKEN_PATTERNS.items():
            if pattern.search(data):
                token_findings.append({"pattern": pattern_id, "path": relative, "file_sha256": evidence[relative]})
    browser_cells = [(paper["short_id"], surface, profile, cell) for paper in capture["papers"] for surface, profiles in paper["browser"].items() for profile, cell in profiles.items()]
    screenshots = [cell["screenshot"] for _, _, _, cell in browser_cells]
    blocked_ids = {"authenticated_studio", "real_assistive_technology", "delivered_mail_clients", "studio_authored_loss_geometry_focus"}
    checks = [
        check("assignment_identity", assignment["assignment_uuid"] == "d75c84e3-5f21-4830-818a-ce2b3f519b2a" and result["assignment_id"] == "restart-experiment-02", "Immutable assignment id and UUID."),
        check("round_exact", result["round"] == "baseline" and b'"round":"baseline"' in handoff_bytes and handoff["round"] == "baseline", "Typed result and compact Cycle handoff contain the exact baseline round."),
        check("authority_scope", result["epic_task_id"] == "task-a768c69e659add58" and result["wave_id"] == "legendary-paper-reader-upgrade-wave-2026-08-06-restart" and result["inventory_digest"] == "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc", "Restart Cycle scope matches the immutable plan."),
        check("manifest_and_server", capture["manifest_override"] == "docs/cli/fixtures/full-manifest.json" and capture["bp_server"] == "guerrilla", "Required manifest override and bp server are frozen."),
        check("paper_pins", [(paper["short_id"], paper["expected_rev"], paper["expected_blocks"]) for paper in capture["papers"]] == [("CCH29", "18768b0a14c2eead927181c4a0e37c18", 252), ("PDS45", "b992fd8aaa028b0dab30a8da76f077fd", 227), ("CCH28", "49c1534d9fb76d0d9adc7b97f25ec471", 237), ("PDS44", "8bbd5d874a1b697f1e4e437c473f8e52", 99)] and all(paper["pin_match"] and paper["block_count_match"] and paper["projection_match"] for paper in capture["papers"]), "All four revision pins, block counts, and CLI projections reproduce."),
        check("denominators", denominators["totals"]["blocks"] == 815 and denominators["totals"]["header_cells"] == 113 and denominators["totals"]["body_cells"] == 1374 and denominators["totals"]["mark_records"] == 388 and denominators["totals"]["headerless_tables"] == 11, "Frozen authored denominators are exact."),
        check("browser_matrix", len(browser_cells) == 48 and all(set(paper["browser"][surface]) == {"desktop", "390", "320", "reflow200"} for paper in capture["papers"] for surface in ("public", "email", "studio")), "Four Papers x three browser surfaces x four profiles = 48 cells."),
        check("reflow_definition", capture["profiles"]["reflow200"] == {"width": 640, "height": 900, "device_scale_factor": 2, "mobile": False}, "200%-equivalent reflow profile is frozen."),
        check("screenshots", len(screenshots) == 48 and all(sha((ROOT / item["path"]).read_bytes()) == item["sha256"] and (ROOT / item["path"]).stat().st_size == item["bytes"] for item in screenshots), "Every browser cell has a hash-verified PNG."),
        check("studio_login_block", all(cell["authGate"] for _, surface, _, cell in browser_cells if surface == "studio"), "Every fresh anonymous Studio profile reaches the login gate."),
        check("blocked_never_proxy_pass", all(item["status"] == "BLOCKED" and item["passed"] == 0 for item in score["gates"] if item["id"] in blocked_ids) and {item["id"] for item in score["gates"] if item["id"] in blocked_ids} == blocked_ids, "Studio, AT, and delivered mail gaps remain blocked with zero passes."),
        check("hard_verdict", score["summary"]["FAIL"] > 0 and score["summary"]["BLOCKED"] > 0 and result["verdict"] == "BASELINE_FAIL_WITH_BLOCKED_SURFACES", "Hard failures or blocked surfaces cannot average to a pass."),
        check("no_candidate_or_mutation_claim", result["candidate_ids"] == [] and all(result[key] is False for key in ("production_mutated", "paper_mutated", "task_mutated", "cycle_mutated")), "This baseline declares no candidate or authoritative mutation."),
        check("mutation_proof", mutation["pass"] and mutation["git_head"] == "d6df2c4d71d255f6c9fdc3b527ce9675b4f57b80" and not mutation["tracked_status"] and all(item["unchanged"] for item in mutation["live_pins"]), "Tracked worktree is unchanged and all four live revision/content pins remain fixed."),
        check("raw_studio_credentials_not_persisted", all(not paper["http"]["studio"]["body_persisted"] and paper["http"]["studio"]["path"].endswith("studio-response-metadata.json") for paper in capture["papers"]), "Session-bound Studio login bodies are not persisted."),
        check("redacted_cookie_values", all(cookie.get("value") == "NOT_CAPTURED" for paper in redacted["papers"] for profiles in paper["browser"].values() for cell in profiles.values() for cookie in cell["sessionCookieMetadata"]), "Redacted manifest contains cookie metadata only."),
        check("token_scan", not token_findings, "High-confidence credential scan has zero findings."),
    ]
    token_payload = {"schema_version": "legendary-restart-e02-token-scan/v1", "files_scanned": len(evidence), "patterns": sorted(TOKEN_PATTERNS), "finding_count": len(token_findings), "findings": token_findings, "verdict": "PASS" if not token_findings else "FAIL"}
    (ROOT / "token-scan.json").write_bytes(canonical(token_payload) + b"\n")
    (ROOT / "artifact-hashes.json").write_bytes(canonical({"schema_version": "legendary-restart-e02-artifact-hashes/v1", "files": evidence, "aggregate_sha256": sha(canonical(evidence))}) + b"\n")
    payload = {"schema_version": "legendary-restart-e02-verification/v1", "verdict": "PASS" if all(item["pass"] for item in checks) else "FAIL", "checks": checks, "checks_passed": sum(item["pass"] for item in checks), "checks_total": len(checks), "evidence_file_count": len(evidence), "evidence_aggregate_sha256": sha(canonical(evidence)), "token_scan_verdict": token_payload["verdict"]}
    data = canonical(payload) + b"\n"
    (ROOT / "verification.json").write_bytes(data)
    digest = sha(data)
    (ROOT / "verification.sha256").write_text(digest + "\n")
    print(json.dumps({"verdict": payload["verdict"], "verification_sha256": digest, "evidence_aggregate_sha256": payload["evidence_aggregate_sha256"], "checks_passed": payload["checks_passed"], "checks_total": payload["checks_total"], "token_scan": payload["token_scan_verdict"]}, sort_keys=True))
    raise SystemExit(0 if payload["verdict"] == "PASS" else 1)


if __name__ == "__main__":
    main()
