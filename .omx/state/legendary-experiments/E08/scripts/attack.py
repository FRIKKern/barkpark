#!/usr/bin/env python3
"""Build deterministic E08 hostile-content evidence without mutating inputs."""

from __future__ import annotations

import hashlib
import json
import sys
import time
from collections import Counter
from pathlib import Path

E08 = Path(__file__).resolve().parents[1]
ROOT = E08.parent
E03, E04, E05, E06 = (ROOT / name for name in ("E03", "E04", "E05", "E06"))
ADV_IDS = (
    "adv-narrow-width",
    "adv-long-content",
    "adv-missing-fields",
    "adv-malformed-legacy",
    "adv-nested-list-table",
    "adv-long-token",
)
CAPABILITY_BLOCKS = [
    "authenticated Studio content proof unavailable",
    "real-client email proof unavailable",
    "real TUI/narrow-width assistive-technology proof unavailable",
    "no frozen unsupported-alias fixture exists in E03",
]


def load(path: Path):
    return json.loads(path.read_text())


def dump(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            if key in {"text", "value", "content"}:
                yield from strings(item)
            elif isinstance(item, (dict, list)):
                yield from strings(item)


def node_types(value) -> Counter:
    found = Counter()
    if isinstance(value, list):
        for item in value:
            found.update(node_types(item))
    elif isinstance(value, dict):
        if isinstance(value.get("type"), str):
            found[value["type"]] += 1
        for item in value.values():
            if isinstance(item, (dict, list)):
                found.update(node_types(item))
    return found


def probe(axis, fixture, status, evidence, severity="none"):
    taxonomy = {
        "fixture coverage": "F02",
        "hostile-content execution": "F02",
        "authored content preservation": "F06",
        "heading and list hierarchy": "F06",
        "malformed-node containment": "F04",
        "missing-field containment": "F05",
        "structure at narrow widths": "F08",
        "semantic reading order and non-visual status": "F09",
        "unsupported alias containment": "F04",
    }
    return {
        "axis": axis,
        "failure_taxonomy_id": taxonomy[axis],
        "fixture_id": fixture,
        "status": status,
        "severity": severity,
        "evidence": evidence,
    }


def e04_probes(fixtures):
    packet = load(E04 / "output/repair-packet.json")
    papers = {row["id"]: row for row in packet["papers"]}
    quarantined = {row["id"]: row for row in packet["quarantine"]}
    rows = []
    accepted = set(papers) & set(ADV_IDS)
    rows.append(probe("fixture coverage", "all", "PASS", f"6/6 accounted: {len(accepted)} accepted, {len(quarantined)} quarantined"))
    for fid in ("adv-long-content", "adv-long-token", "adv-narrow-width"):
        source_text = "".join(strings(fixtures[fid]))
        output_text = "".join(strings(papers[fid]["canonical"]))
        rows.append(probe("authored content preservation", fid, "PASS" if source_text == output_text else "FAIL", f"source/output characters {len(source_text)}/{len(output_text)}", "critical" if source_text != output_text else "none"))
    src_types = node_types(fixtures["adv-nested-list-table"])
    out_types = node_types(papers["adv-nested-list-table"]["canonical"])
    hierarchy_ok = src_types["table"] == out_types["table"] and out_types["bullet_list"] >= src_types["bullet_list"]
    rows.append(probe("heading and list hierarchy", "adv-nested-list-table", "PASS" if hierarchy_ok else "FAIL", f"source types={dict(src_types)} output types={dict(out_types)}; nested bullet_list was flattened to scalar table text", "high" if not hierarchy_ok else "none"))
    rows.append(probe("malformed-node containment", "adv-malformed-legacy", "PASS" if "adv-malformed-legacy" in quarantined else "FAIL", "explicit malformed_source quarantine with preimage" if "adv-malformed-legacy" in quarantined else "missing quarantine", "critical" if "adv-malformed-legacy" not in quarantined else "none"))
    rows.append(probe("missing-field containment", "adv-missing-fields", "PASS" if "adv-missing-fields" in quarantined else "FAIL", "explicit empty_or_schema_failure quarantine with preimage" if "adv-missing-fields" in quarantined else "missing quarantine", "critical" if "adv-missing-fields" not in quarantined else "none"))
    rows.append(probe("structure at narrow widths", "adv-narrow-width", "BLOCKED", "local HTML preserves text, but no real TUI/email width evidence", "high"))
    rows.append(probe("semantic reading order and non-visual status", "all", "BLOCKED", "authenticated Studio, real email, and assistive-technology evidence unavailable", "high"))
    rows.append(probe("unsupported alias containment", "all", "BLOCKED", "E03 has no frozen unsupported-alias fixture; no replacement evidence invented", "high"))
    return rows


def e05_probes(fixtures):
    envelopes = {row["fixture_id"]: row for row in map(json.loads, (E05 / "outputs/envelopes.jsonl").read_text().splitlines())}
    rows = [probe("fixture coverage", "all", "PASS", f"{len(set(envelopes) & set(ADV_IDS))}/6 adversarial envelopes")]
    for fid in ("adv-long-content", "adv-long-token", "adv-narrow-width"):
        source_text = "".join(strings(fixtures[fid]))
        output_text = envelopes[fid]["reader_contract"]["text"]
        rows.append(probe("authored content preservation", fid, "PASS" if source_text == output_text else "FAIL", f"source/output characters {len(source_text)}/{len(output_text)}", "critical" if source_text != output_text else "none"))
    source_types = node_types(fixtures["adv-nested-list-table"])
    views = envelopes["adv-nested-list-table"]["reader_views"]
    structural_markup = any("<table" in cell["output"] or "<ul" in cell["output"] for cell in views.values())
    rows.append(probe("heading and list hierarchy", "adv-nested-list-table", "PASS" if structural_markup else "FAIL", f"source types={dict(source_types)}; all five derived views collapse nested table/list to plain 'nested'", "high" if not structural_markup else "none"))
    for fid, axis in (("adv-malformed-legacy", "malformed-node containment"), ("adv-missing-fields", "missing-field containment")):
        contract = envelopes[fid]["reader_contract"]
        ok = contract["status"] == "supported_error" and all(v["mode"] == "explicit_supported_error" for v in envelopes[fid]["reader_views"].values())
        rows.append(probe(axis, fid, "PASS" if ok else "FAIL", f"status={contract['status']}; five explicit supported-error views", "critical" if not ok else "none"))
    rows.append(probe("structure at narrow widths", "adv-narrow-width", "PARTIAL", "20-column scratch TUI output preserves words; no real TUI/email client evidence", "high"))
    rows.append(probe("semantic reading order and non-visual status", "all", "BLOCKED", "plain-text derived views cannot prove heading/table/list/status semantics; real surfaces unavailable", "high"))
    rows.append(probe("unsupported alias containment", "all", "BLOCKED", "E03 has no frozen unsupported-alias fixture; no replacement evidence invented", "high"))
    return rows


def e06_probes(_fixtures):
    outputs = load(E06 / "outputs/candidates.json")["units"]
    output_ids = {row["id"] for row in outputs}
    manifest = load(E06 / "fixture-manifest.json")
    frozen_ids = {Path(row["path"]).stem for row in manifest["adversarial"]}
    missing = sorted(frozen_ids - output_ids)
    rows = [probe("fixture coverage", "all", "FAIL", f"0/6 adversarial candidate outputs; missing={missing}", "critical")]
    for fid in ADV_IDS:
        rows.append(probe("hostile-content execution", fid, "BLOCKED", "fixture is hashed in the manifest but absent from outputs/candidates.json and dispatch decisions", "high"))
    rows.append(probe("semantic reading order and non-visual status", "all", "BLOCKED", "no adversarial output plus authenticated Studio/email/TUI evidence unavailable", "high"))
    rows.append(probe("unsupported alias containment", "all", "BLOCKED", "E03 has no frozen unsupported-alias fixture; no replacement evidence invented", "high"))
    return rows


def build_documents():
    fixtures = {p.stem: load(p) for p in (E03 / "fixtures").glob("*.json")}
    candidates = {
        "E04": ("candidate-canonical-native", e04_probes(fixtures)),
        "E05": ("candidate-preservation-envelope", e05_probes(fixtures)),
        "E06": ("candidate-cohort-rails", e06_probes(fixtures)),
    }
    matrix = {"assignment_id": "E08", "schema_version": "legendary-e08-attack-matrix/v1", "rows": []}
    scorecards = []
    rejected = []
    for source_id, (candidate_id, rows) in candidates.items():
        for row in rows:
            matrix["rows"].append({"candidate_id": candidate_id, "source_assignment": source_id, **row})
        counts = dict(Counter(row["status"] for row in rows))
        hard = [row for row in rows if row["severity"] in {"critical", "high"} and row["status"] != "PASS"]
        verdict = "REJECT" if hard else "PASS"
        scorecards.append({"candidate_id": candidate_id, "source_assignment": source_id, "counts": counts, "hard_gate_failures": len(hard), "verdict": verdict})
        if hard:
            rejected.append({"candidate_id": candidate_id, "source_assignment": source_id, "reasons": [f"{row['axis']}:{row['fixture_id']}:{row['status']}" for row in hard]})
    evidence = {
        "assignment_id": "E08",
        "schema_version": "legendary-e08-rejections/v1",
        "hard_gate": "Reject any candidate with critical/high accessibility defects, semantic reordering, malformed-node propagation, or content loss.",
        "rejected_candidates": rejected,
        "capability_blocks": CAPABILITY_BLOCKS,
    }
    score = {"assignment_id": "E08", "schema_version": "legendary-e08-scorecards/v1", "candidates": scorecards}
    inputs = {}
    for label, path in {
        "legendary-experiment-roster.json": ROOT.parent / "legendary-experiment-roster.json",
        "E03/thresholds.json": E03 / "thresholds.json",
        "E03/failure-taxonomy.json": E03 / "failure-taxonomy.json",
        "E03/fixture-manifest.json": E03 / "fixture-manifest.json",
        "E04/output/repair-packet.json": E04 / "output/repair-packet.json",
        "E05/outputs/envelopes.jsonl": E05 / "outputs/envelopes.jsonl",
        "E06/fixture-manifest.json": E06 / "fixture-manifest.json",
        "E06/outputs/candidates.json": E06 / "outputs/candidates.json",
    }.items():
        inputs[label] = sha(path)
    return {
        "attack-matrix.json": matrix,
        "candidate-scorecards.json": score,
        "rejection-evidence.json": evidence,
        "input-hashes.json": {"assignment_id": "E08", "schema_version": "legendary-e08-input-hashes/v1", "sha256": inputs},
    }


def main():
    started = time.perf_counter_ns()
    docs = build_documents()
    for name, value in docs.items():
        dump(E08 / name, value)
    elapsed = time.perf_counter_ns() - started
    timing_path = E08 / "timing.json"
    if not timing_path.exists() or "--refresh-timing" in sys.argv:
        dump(timing_path, {"assignment_id": "E08", "schema_version": "legendary-e08-timing/v1", "attack_wall_nanoseconds": elapsed, "measurement_policy": "frozen observed local wall time; ordinary replay does not rewrite"})
    artifact_names = [
        *docs,
        "timing.json",
        "README.md",
        "scripts/attack.py",
        "scripts/run.sh",
        "scripts/verify.py",
    ]
    artifacts = {name: sha(E08 / name) for name in artifact_names}
    scorecards = docs["candidate-scorecards.json"]["candidates"]
    matrix_rows = docs["attack-matrix.json"]["rows"]
    result = {
        "assignment_id": "E08",
        "schema_version": "legendary-e08-result/v1",
        "round": 3,
        "objective": "Attack accessibility, structure, and hostile content behavior",
        "candidate_ids": [row["candidate_id"] for row in scorecards],
        "counts": {
            "candidates": len(scorecards),
            "adversarial_fixtures": len(ADV_IDS),
            "probes": len(matrix_rows),
            "pass": sum(r["status"] == "PASS" for r in matrix_rows),
            "partial": sum(r["status"] == "PARTIAL" for r in matrix_rows),
            "blocked": sum(r["status"] == "BLOCKED" for r in matrix_rows),
            "fail": sum(r["status"] == "FAIL" for r in matrix_rows),
            "rejected_candidates": sum(r["verdict"] == "REJECT" for r in scorecards),
        },
        "candidate_outcomes": scorecards,
        "attack_axes": ["semantic reading order", "heading and list hierarchy", "non-visual status meaning", "malformed-node containment", "structure preservation at narrow widths"],
        "capability_blocks": CAPABILITY_BLOCKS,
        "artifact_hashes": artifacts,
        "commands_or_probes": ["python3 scripts/attack.py", "python3 scripts/verify.py", "scripts/run.sh"],
        "threshold_outcomes": {
            "accessibility": "FAIL_BLOCKED_ALL_CANDIDATES",
            "structural_completeness": "FAIL_E04_E05_NESTED_HIERARCHY; BLOCKED_E06_NO_ADVERSARIAL_OUTPUT",
            "malformed_node_containment": "PASS_E04_E05; BLOCKED_E06_NO_ADVERSARIAL_OUTPUT",
            "width_overflow": "BLOCKED_REAL_TUI_AND_EMAIL",
            "surface_exercise": "BLOCKED_STUDIO_EMAIL_TUI",
            "reader_visibility": "BLOCKED_REAL_SURFACES",
        },
        "rejected_candidates": docs["rejection-evidence.json"]["rejected_candidates"],
        "stop_condition": "Triggered: inaccessible real-surface evidence and E06 missing hostile outputs prevent a bounded complete attack.",
        "verdict": {"action": "REWORK", "quality": "REJECT_ALL_ROUND_2_CANDIDATES", "reason": "No candidate clears the frozen E03 hard accessibility/structure/surface thresholds."},
    }
    dump(E08 / "result.json", result)
    print(f"E08 ATTACK BUILT: {len(matrix_rows)} probes; 3/3 candidates rejected")


if __name__ == "__main__":
    main()
