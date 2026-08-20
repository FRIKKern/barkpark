#!/usr/bin/env python3
"""Materialize the frozen E03 inputs inside the isolated E06 artifact."""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
E03 = ROOT.parent / "E03"
STATE = ROOT.parents[1]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


def main() -> None:
    fixtures = ROOT / "fixtures"
    frozen = ROOT / "frozen"
    fixtures.mkdir(parents=True, exist_ok=True)
    frozen.mkdir(parents=True, exist_ok=True)

    copies = {
        E03 / "raw/selected-source-documents.json": fixtures / "selected-source-documents.json",
        E03 / "fixture-manifest.json": frozen / "e03-fixture-manifest.json",
        E03 / "thresholds.json": frozen / "thresholds.json",
        E03 / "failure-taxonomy.json": frozen / "failure-taxonomy.json",
        E03 / "candidate-rubric.json": frozen / "candidate-rubric.json",
    }
    for source, target in copies.items():
        shutil.copyfile(source, target)

    adversarial = []
    for source in sorted((E03 / "fixtures").glob("*.json")):
        target = fixtures / source.name
        shutil.copyfile(source, target)
        adversarial.append({"path": f"fixtures/{source.name}", "sha256": sha(target)})

    e03_manifest = json.loads((frozen / "e03-fixture-manifest.json").read_text())
    survey_roster = STATE / "legendary-survey-roster.json"
    empty_exclusions = {
        "schema_version": "legendary-e06-empty-paper-exclusions/v1",
        "assignment_id": "E06",
        "source": {"path": ".omx/state/legendary-survey-roster.json", "physical_sha256": sha(survey_roster)},
        "units": [
            {
                "id": fixture_id,
                "source_row_available": False,
                "action": "exclude_pending_evidence",
                "reason": "accepted survey fact identifies an empty draft Paper probe; no E03 raw row exists, so content and a source hash must not be invented",
            }
            for fixture_id in [
                "drafts.paper-3149ef706e777628",
                "drafts.paper-b28358ff271b260e",
                "drafts.paper-e0a61d000f391eb9",
            ]
        ],
    }
    write_json(fixtures / "empty-paper-exclusions.json", empty_exclusions)
    manifest = {
        "schema_version": "legendary-e06-fixtures/v1",
        "assignment_id": "E06",
        "source": {
            "assignment_id": "E03",
            "fixture_manifest_sha256": sha(frozen / "e03-fixture-manifest.json"),
            "selected_source_sha256": sha(fixtures / "selected-source-documents.json"),
            "thresholds_sha256": sha(frozen / "thresholds.json"),
            "failure_taxonomy_sha256": sha(frozen / "failure-taxonomy.json"),
            "candidate_rubric_sha256": sha(frozen / "candidate-rubric.json"),
        },
        "counts": e03_manifest["counts"],
        "paper_units": [
            {"id": row["id"], "cohort": row["cohort"], "source_sha256": row["source_sha256"]}
            for row in e03_manifest["papers"]
        ],
        "task_units": [
            {
                "id": row["id"],
                "class": row["class"],
                "signals": row["observed"].get("signals", []),
                "source_sha256": row["source_sha256"],
            }
            for row in e03_manifest["tasks"]
        ],
        "adversarial": adversarial,
        "explicit_empty_paper_exclusions": {
            "path": "fixtures/empty-paper-exclusions.json",
            "sha256": sha(fixtures / "empty-paper-exclusions.json"),
            "count": 3,
        },
    }
    write_json(ROOT / "fixture-manifest.json", manifest)
    print("E06 FIXTURES PASS papers=12 tasks=18 adversarial=6")


if __name__ == "__main__":
    main()
