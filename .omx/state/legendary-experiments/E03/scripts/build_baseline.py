#!/usr/bin/env python3
"""Build E03's frozen, replayable baseline fixtures from E01/E02 evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
UNSUPPORTED_TYPES = {"bulletList", "bullet_list", "bulleted_list", "numbered_list", "quote"}
PAPER_IDS = {
    "conditional_control": [
        "component-reference",
        "choosing-your-site-framework",
        "wave-deck",
    ],
    "markdown_only_failure": [
        "aesthetic-unification-epic-wave-2026-07-11",
        "authoring-excellence-wave-2026-07-13",
        "authoring-excellence-wave-2026-07-13b",
        "bp-mcp-serve-epic-wave-2026-07-11",
        "cloud-console-wave-2026-07-11",
        "pd-everything-editable-wave-2026-07-11",
    ],
    "unsupported_nested": ["perfect-plan-build-wave-5-2026-07-14"],
    "html_only_control": ["onboarding-composition-wave-2026-07-14"],
    "legacy_root_control": ["autorebuild-proof-164347"],
}
TASK_IDS = {
    "executable": ["au-w6-brand-mark", "au-w6-visual-audit", "drafts.paper-editor-parity-wave3"],
    "goal": ["drafts.task-a54820a835b6d0e2", "task-1bb04ac51efec9af", "ag-deny-matrix-residual-coverage"],
    "decision_or_human_gate": [
        "bp-task-stamp-criterion-index-is-zero-based-footgun",
        "pd-everything-editable",
        "task-4e4a53b101a97051",
    ],
    "done_or_cancelled_history": ["ag-studio-access-panel-countdown", "drafts.probe-rail-move", "era-w8-epic-rollup"],
    "deferred": ["ag-broadcast-revoked-residual", "dwb", "hq-heatmap-live-lever"],
    "probe": ["drafts.task-0f79e6c78378b9aa", "drafts.task-823a80389028877b", "drafts.task-859af59466f08494"],
}


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_json(path: Path, value: Any) -> str:
    payload = canonical_bytes(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return digest_bytes(payload)


def load_documents(path: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    payload = json.loads(path.read_text())
    return ({key: value for key, value in payload.items() if key != "documents"}, {row["_id"]: row for row in payload["documents"]})


def iter_nodes(value: Any, path: str = ""):
    if isinstance(value, dict):
        if isinstance(value.get("type"), str):
            yield path or "/", value
        for key, child in value.items():
            yield from iter_nodes(child, f"{path}/{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from iter_nodes(child, f"{path}/{index}")


def paper_facts(row: dict[str, Any], cohort: str) -> dict[str, Any]:
    body = row.get("body")
    top_blocks = row.get("blocks")
    unsupported = [
        {"path": path, "type": node["type"]}
        for path, node in iter_nodes(body if isinstance(body, dict) else top_blocks)
        if node["type"] in UNSUPPORTED_TYPES
    ]
    return {
        "id": row["_id"],
        "rev": row.get("_rev"),
        "cohort": cohort,
        "source_sha256": digest_bytes(canonical_bytes(row)),
        "observed": {
            "body_is_portabledoc": isinstance(body, dict),
            "body_is_markdown": isinstance(body, str) and bool(body.strip()),
            "top_level_blocks": len(top_blocks) if isinstance(top_blocks, list) else 0,
            "body_blocks": len(body.get("blocks", [])) if isinstance(body, dict) else 0,
            "body_html_present": isinstance(row.get("body_html"), str) and bool(row["body_html"].strip()),
            "unsupported_nodes": unsupported,
        },
        "rating_boundary": "control is conditional; no fixture is assumed gold",
    }


def adversarial_fixtures() -> list[dict[str, Any]]:
    return [
        {"id": "adv-narrow-width", "kind": "narrow_width", "width_columns": 20, "content": "alpha beta gamma delta epsilon"},
        {"id": "adv-long-content", "kind": "long_content", "body": {"blocks": [{"type": "paragraph", "text": "long paragraph " * 500}]}},
        {"id": "adv-missing-fields", "kind": "missing_fields", "_type": "paper", "body": {"blocks": []}},
        {"id": "adv-malformed-legacy", "kind": "malformed_legacy_nodes", "blocks": [{"type": 7, "children": "not-a-list"}]},
        {"id": "adv-nested-list-table", "kind": "nested_lists_tables", "body": {"blocks": [{"type": "table", "rows": [[{"type": "bullet_list", "items": [[{"type": "text", "value": "nested"}]]}]]}]}},
        {"id": "adv-long-token", "kind": "long_unbroken_tokens", "body": {"blocks": [{"type": "paragraph", "text": "x" * 4096}]}},
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--paper-response", type=Path, required=True)
    parser.add_argument("--task-response", type=Path, action="append", required=True)
    parser.add_argument("--paper-manifest", type=Path, required=True)
    parser.add_argument("--task-manifest", type=Path, required=True)
    parser.add_argument("--classification-source", type=Path, required=True)
    args = parser.parse_args()

    paper_meta, paper_docs = load_documents(args.paper_response)
    task_meta, task_docs = {}, {}
    for path in args.task_response:
        meta, docs = load_documents(path)
        task_meta[path.name] = meta
        task_docs.update(docs)

    e01 = json.loads(args.paper_manifest.read_text())
    e02 = json.loads(args.task_manifest.read_text())
    classification = json.loads(args.classification_source.read_text())
    class_rows = {row["id"]: row for row in classification["rows"]}
    paper_membership = set(e01["membership"]["ids"])
    class_membership = {
        name: set(value["ordered_ids"])
        for name, value in e02["classification"]["classes"].items()
    }
    signal_sets = {name.lower(): set(value["ids"]) for name, value in classification["cohorts"].items()}
    signal_sets["ambiguous"] = set(classification["ambiguous"]["ids"])
    signal_sets["class_vs_cn_disagreement"] = set(classification["disagreements"]["ids"])

    papers = []
    for cohort, ids in PAPER_IDS.items():
        for fixture_id in ids:
            assert fixture_id in paper_membership, (fixture_id, "not in E01")
            assert fixture_id in paper_docs, (fixture_id, "not in raw response")
            papers.append(paper_facts(paper_docs[fixture_id], cohort))
    assert len(papers) == 12 and len({row["id"] for row in papers}) == 12
    assert sum(row["cohort"] == "markdown_only_failure" for row in papers) == 6

    tasks = []
    for class_name, ids in TASK_IDS.items():
        assert len(ids) == 3
        for fixture_id in ids:
            assert fixture_id in class_membership[class_name], (fixture_id, class_name)
            assert fixture_id in task_docs, (fixture_id, "not in raw response")
            source = class_rows[fixture_id]
            tasks.append({
                "id": fixture_id,
                "class": class_name,
                "rev": source["rev"],
                "source_sha256": digest_bytes(canonical_bytes(task_docs[fixture_id])),
                "observed": {
                    "lifecycle": source["lifecycle"],
                    "cn": source["cn"],
                    "cn_gaps": source["cn_gaps"],
                    "mechanical_parts": source["parts"],
                    "mechanical_class_score": source["class_score"],
                    "source_candidate_rating": source["rating"],
                    "signals": sorted(name for name, ids_set in signal_sets.items() if fixture_id in ids_set),
                },
                "rating_boundary": "E02 mechanical candidate rating is inference, not final product truth",
            })
    assert len(tasks) == 18 and len({row["id"] for row in tasks}) == 18
    assert {row["class"] for row in tasks} == set(TASK_IDS)
    covered_signals = {signal for row in tasks for signal in row["observed"]["signals"]}
    assert {"p0", "p1", "p2", "retire", "human_review", "ambiguous", "class_vs_cn_disagreement"} <= covered_signals

    adversarial = adversarial_fixtures()
    adversarial_rows = []
    for fixture in adversarial:
        path = ROOT / "fixtures" / f"{fixture['id']}.json"
        fixture_hash = write_json(path, fixture)
        adversarial_rows.append({"id": fixture["id"], "kind": fixture["kind"], "path": str(path.relative_to(ROOT)), "sha256": fixture_hash})

    selected_raw = {
        "schema_version": "e03-selected-raw/v1",
        "paper_query_metadata": paper_meta,
        "task_query_metadata": task_meta,
        "papers": [paper_docs[row["id"]] for row in papers],
        "tasks": [task_docs[row["id"]] for row in tasks],
    }
    selected_raw_sha = write_json(ROOT / "raw" / "selected-source-documents.json", selected_raw)
    manifest = {
        "schema_version": "legendary-e03-baseline-fixtures/v1",
        "assignment_id": "E03",
        "counts": {"papers": 12, "tasks": 18, "adversarial": 6, "total": 36},
        "source_manifests": {
            "E01": {"path": str(args.paper_manifest), "physical_sha256": digest_bytes(args.paper_manifest.read_bytes())},
            "E02": {"path": str(args.task_manifest), "physical_sha256": digest_bytes(args.task_manifest.read_bytes())},
            "E02_classification_source": {"path": str(args.classification_source), "physical_sha256": digest_bytes(args.classification_source.read_bytes())},
        },
        "papers": papers,
        "tasks": tasks,
        "adversarial": adversarial_rows,
        "selected_raw": {"path": "raw/selected-source-documents.json", "sha256": selected_raw_sha},
        "reconciliation": {
            "paper_ids_unique": True,
            "paper_ids_in_E01": True,
            "task_ids_unique": True,
            "task_ids_in_disjoint_E02_classes": True,
            "required_task_signals": sorted(covered_signals),
            "overlap_count": 0,
        },
    }
    manifest_sha = write_json(ROOT / "fixture-manifest.json", manifest)
    print(json.dumps({"manifest_sha256": manifest_sha, "counts": manifest["counts"], "task_signals": sorted(covered_signals)}, indent=2))


if __name__ == "__main__":
    main()
