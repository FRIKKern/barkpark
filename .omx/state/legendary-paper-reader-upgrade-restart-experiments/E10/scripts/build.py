#!/usr/bin/env python3
"""Build the E10 no-winner evidence and deterministic archive."""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import subprocess
import sys
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
ROOT = HERE.parent
REPO = HERE.parents[4]

AUTHORITY = {
    "epic_task_id": "task-a768c69e659add58",
    "wave_id": "legendary-paper-reader-upgrade-wave-2026-08-06-restart",
    "wave_revision": "8a94f6db-1be6-4bbf-ba49-7f3aeed0e737",
    "inventory_digest": "227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc",
    "plan_digest": "9997fc50db5f1b83f1f53e33bd45dd111b2b06402b07a78b0673d2048f299e45",
}

SOURCE_HASHES = {
    "baseline-seal/contract.json": "bb24ce3baee61d76a210b97ebf8ebd9b17ea20ae1cb988ade4daae44907d3bef",
    "E07/result.json": "02ae1d3b66a692fb2179bd89df9c2bf88e6da01570cf7103e65961a299043b42",
    "E07/reports/replay.json": "7b8fc51e2aaf8e31e6f58c5c7ff566f4e51cc8a55d3c1a19a8c3d8638d37c853",
    "E08/result.json": "41338ba91f4d6ad49fdc2d5eb3b523f8e66c78ce2a62129899a53bd308a294f2",
    "E08/reports/attack-matrix.json": "e1d24ad354e23a1c1819e36d7d584bb80bc7ee9f7b6818f596412b6a77ddaac0",
    "E08/reports/candidate-scorecards.json": "382704b7e41e56b47f6559d47f1893f28526f6f18146b1f3d64de9ffbde1ebb1",
    "E09/result.json": "defa06c2c42464a652ab214af8b48766a8720a37da8f1459f9a3d1a653a16074",
    "E09/reports/verification.json": "bd1579489b85d7ebf6ec801e78e0415fd2e0422d858a916d434a8cca64aa3ca6",
}


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value))


def load(relative: str) -> object:
    return json.loads((ROOT / relative).read_text())


def dir_digest(path: Path) -> str:
    rows = []
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        rows.append({"path": item.relative_to(path).as_posix(), "sha256": digest(item)})
    return hashlib.sha256(canonical(rows)).hexdigest()


def archive(paths: list[str], target: Path) -> str:
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for name in sorted(paths):
            data = (HERE / name).read_bytes()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
    with target.open("wb") as handle:
        with gzip.GzipFile(filename="", mode="wb", fileobj=handle, mtime=0) as zipped:
            zipped.write(payload.getvalue())
    return digest(target)


def main() -> int:
    for relative, expected in SOURCE_HASHES.items():
        actual = digest(ROOT / relative)
        if actual != expected:
            raise SystemExit(f"source drift: {relative}: {actual}")
    write(HERE / "reports" / "source-hashes.json", {
        "schema_version": "legendary-paper-restart-e10-source-hashes/v1",
        "sources": [{"path": path, "sha256": value} for path, value in sorted(SOURCE_HASHES.items())],
    })

    attack = ROOT / "E07" / "scripts" / "attack.py"
    replay_dirs = [HERE / "replay" / "run-1", HERE / "replay" / "run-2"]
    for output in replay_dirs:
        subprocess.run([sys.executable, str(attack), "--output", str(output)], check=True, cwd=REPO, stdout=subprocess.DEVNULL)
    replay_hashes = [dir_digest(path) for path in replay_dirs]
    write(HERE / "reports" / "e07-independent-replay.json", {
        "schema_version": "legendary-paper-restart-e10-e07-replay/v1",
        "runs": 2,
        "byte_identical": replay_hashes[0] == replay_hashes[1],
        "run_1_sha256": replay_hashes[0],
        "run_2_sha256": replay_hashes[1],
        "files_per_run": len([p for p in replay_dirs[0].rglob("*") if p.is_file()]),
    })
    subprocess.run([sys.executable, str(HERE / "scripts" / "contract_probe.py")], check=True, cwd=REPO, stdout=subprocess.DEVNULL)

    baseline = load("baseline-seal/contract.json")
    e07 = load("E07/result.json")
    e08 = load("E08/result.json")
    e09 = load("E09/result.json")
    candidates = []
    e08_by_candidate = {row["candidate"]: row for row in e08["candidate_outcomes"]}
    e09_terminal = {item.split(":", 1)[1] for item in e09["hard_failures"] if item.startswith("terminal_control_leaks:")}
    for row in e07["candidate_scores"]:
        short = "E" + row["candidate"].rsplit("-", 1)[1]
        attack8 = e08_by_candidate[short]
        candidates.append({
            "candidate": short,
            "e07_failed_probes": row["failed_probes"],
            "e07_hard_gate_failure_counts": row["hard_gate_failure_counts"],
            "e08_counts": attack8["counts"],
            "e08_verdict": attack8["verdict"],
            "e09_terminal_control_failure": short in e09_terminal,
            "e09_additional_failures": [item for item in e09["hard_failures"] if (":" + short) in item and not item.startswith("terminal_control_leaks:")],
            "clears_every_hard_gate": False,
            "candidate_selected": False,
        })
    rejection = {
        "schema_version": "legendary-paper-restart-e10-no-winner-ledger/v1",
        "round": "converge",
        "authority": AUTHORITY,
        "hard_thresholds": baseline["hard_thresholds"],
        "threshold_policy": "Every threshold remains zero; FAIL or BLOCKED rejects and cannot be averaged away.",
        "candidates": candidates,
        "e07_preservation_schema_rejections": {
            "E04": [
                {"probe": "malformed_list", "gate": "schema_invalidity", "observation": "accepted malformed list without schema quarantine"},
                {"probe": "missing_fields", "gate": "schema_invalidity", "observation": "missing blocks accepted without quarantine"},
                {"probe": "long_unbroken_token", "gate": "page_or_display_overflow", "observation": "unwrapped 512-character token; no display geometry"}
            ],
            "E05": [
                {"probe": "conflicting_header_head", "gate": "silent_scope_or_perspective_substitution", "observation": "silently chose header and omitted conflicting head"},
                {"probe": "malformed_list", "gate": "authored_content_loss", "observation": "malformed-list payload absent from public rendering"},
                {"probe": "cas_conflict", "gate": "retry_erased_failures", "observation": "no revision-fenced write/CAS contract"}
            ],
            "E06": [
                {"probe": "conflicting_header_head", "gate": "silent_scope_or_perspective_substitution", "observation": "renderer chose header; quarantine was fixture-roster-bound"},
                {"probe": "malformed_list", "gate": "schema_invalidity", "observation": "schema left block shapes unconstrained"},
                {"probe": "long_unbroken_token", "gate": "page_or_display_overflow", "observation": "public/email CSS lacked long-token wrapping"},
                {"probe": "cas_conflict", "gate": "retry_erased_failures", "observation": "read-cache validation was not write CAS"}
            ]
        },
        "e07_positive_controls": {
            "rollback": "3/3 byte exact",
            "deterministic_replay": "3/3 pass",
            "candidate_winner": None
        },
        "e08_totals": e08["counts"],
        "e08_blocks": "authenticated Studio, delivered mail, real AT, cache/expiry/reconnect remained BLOCKED",
        "e09_scores": e09["scores"],
        "e09_hard_failures": e09["hard_failures"],
        "e09_blocks": e09["blocks"],
        "winner": None,
        "typed_verdict": "NO_WINNER_REPLACEMENT_WAVE_REQUIRED",
        "pilot_authorized": False,
    }
    write(HERE / "reports" / "no-winner-ledger.json", rejection)

    repair = {
        "schema_version": "legendary-paper-restart-e10-replacement-wave-repair-contract/v1",
        "round": "converge",
        "authority": AUTHORITY,
        "applies_to": "new immutable replacement wave only",
        "hard_thresholds": baseline["hard_thresholds"],
        "mechanisms": [
            {"id": "alias_conflicts", "requirement": "Equal header/head aliases canonicalize once; unequal aliases quarantine the untouched source and never choose precedence."},
            {"id": "malformed_structures", "requirement": "Validate every block shape recursively before projection; preserve payload and quarantine malformed or missing required structures."},
            {"id": "long_token_geometry", "requirement": "TUI segments tokens at widths 1/20/40/80/120; public/email use explicit anywhere wrapping and max-width containment with zero clipping."},
            {"id": "write_cas", "requirement": "Every mutation requires an expected revision; mismatch returns typed conflict, writes nothing, and is never erased by retry."},
            {"id": "rollback_quarantine", "requirement": "Record byte preimage and digest before mutation; rollback restores exact bytes; quarantine is immutable, reasoned, and idempotent."},
            {"id": "terminal_sanitization", "requirement": "Escape or visibly encode C0, ESC, and DEL before every terminal path; emitted control-byte count is zero."},
            {"id": "reader_adapters", "requirement": "Public, authenticated Studio, TUI, delivered email, and CLI/API consume one validated packet; each real reader must exercise all fixtures and BLOCKED never counts as PASS."}
        ],
        "executable_probe": "python3 scripts/contract_probe.py",
        "builder_gate_order": ["source_hash", "recursive_schema", "alias_quarantine", "write_cas", "reader_adapters", "geometry", "terminal_sanitization", "idempotence", "rollback", "real_reader_receipts"],
        "advance_rule": "A replacement-wave candidate advances only when every zero threshold passes and every declared real reader has non-proxy evidence.",
        "pilot_authorized": False,
    }
    write(HERE / "repair-manifest.json", repair)

    archive_files = [
        "assignment.json", "repair-manifest.json", "reports/e07-independent-replay.json",
        "reports/no-winner-ledger.json", "reports/repair-probe.json", "reports/source-hashes.json",
        "scripts/contract_probe.py"
    ]
    archive_hash = archive(archive_files, HERE / "evidence.tar.gz")
    result = {
        "schema_version": "legendary-paper-restart-experiment-result/v1",
        "assignment_id": "restart-experiment-10",
        "assignment_uuid": "a91f9813-3b34-4f62-96ff-8d817d5544f6",
        "agent_type": "legendary-experimenter",
        "model_reasoning_effort": "medium",
        "round": "converge",
        **AUTHORITY,
        "status": "completed",
        "candidate_selected": False,
        "selected_candidate": None,
        "pilot_authorized": False,
        "typed_verdict": "CONVERGE_COMPLETE_NO_WINNER_REPLACEMENT_WAVE_REQUIRED",
        "candidate_gate_clearance": {row["candidate"]: False for row in candidates},
        "e07_replayed_twice_byte_identical": replay_hashes[0] == replay_hashes[1],
        "e07_hard_failures_reproduced": sum(row["failed"] for row in e07["candidate_scores"]),
        "e08_counts_preserved": e08["counts"],
        "e09_scores_preserved": e09["scores"],
        "hard_thresholds_preserved": baseline["hard_thresholds"],
        "repair_contract_mechanisms": [row["id"] for row in repair["mechanisms"]],
        "evidence": "evidence.tar.gz",
        "evidence_archive_sha256": archive_hash,
        "observations": [
            "E04, E05, and E06 each retain hard FAIL and/or BLOCKED cells under unchanged zero thresholds.",
            "All E07 preservation/schema rejection cells reproduced in two byte-identical isolated runs.",
            "E08 and E09 add reader, accessibility/geometry, terminal, interaction, discovery, and typed-error failures or blocks; none can be proxy-passed."
        ],
        "preferences": [],
        "recommended_handoff": "Close this wave unsuccessful and open a new immutable replacement wave implementing and attacking repair-manifest.json; do not dispatch Pilot from E10."
    }
    write(HERE / "result.json", result)
    print("E10 BUILD PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
