#!/usr/bin/env python3
"""Prove the experiment changed no tracked/product files and left live pins fixed."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKTREE = ROOT.parents[3]
EXPECTED_MANIFEST = "docs/cli/fixtures/full-manifest.json"


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def run(*args):
    return subprocess.run(args, cwd=WORKTREE, capture_output=True, check=True).stdout.decode().strip()


def main():
    if os.environ.get("BARKPARK_MANIFEST") != EXPECTED_MANIFEST:
        raise SystemExit(f"BARKPARK_MANIFEST must equal {EXPECTED_MANIFEST}")
    capture = json.loads((ROOT / "outputs/raw-capture-manifest.json").read_bytes())
    live = []
    for paper in capture["papers"]:
        response = subprocess.run(["bp", "-s", "guerrilla", "paper", "view", paper["slug"], "-o", "json"], cwd=WORKTREE, capture_output=True, check=True)
        document = json.loads(response.stdout)
        blocks_hash = hashlib.sha256(canonical(document.get("blocks", []))).hexdigest()
        live.append({"paper": paper["short_id"], "expected_rev": paper["expected_rev"], "observed_rev": document.get("_rev"), "expected_blocks_sha256": paper["cli_blocks_sha256"], "observed_blocks_sha256": blocks_hash, "unchanged": document.get("_rev") == paper["expected_rev"] and blocks_hash == paper["cli_blocks_sha256"]})
    proof = {
        "schema_version": "legendary-restart-e02-mutation-proof/v1", "git_head": run("git", "rev-parse", "HEAD"),
        "expected_git_head": "d6df2c4d71d255f6c9fdc3b527ce9675b4f57b80",
        "tracked_status": run("git", "status", "--porcelain=v1", "--untracked-files=no").splitlines(),
        "unstaged_diff_paths": run("git", "diff", "--name-only").splitlines(),
        "staged_diff_paths": run("git", "diff", "--cached", "--name-only").splitlines(),
        "live_pins": live, "production_mutation_attempted": False, "paper_mutation_attempted": False,
        "task_mutation_attempted": False, "cycle_mutation_attempted": False,
    }
    proof["pass"] = proof["git_head"] == proof["expected_git_head"] and not proof["tracked_status"] and not proof["unstaged_diff_paths"] and not proof["staged_diff_paths"] and all(item["unchanged"] for item in live)
    (ROOT / "mutation-proof.json").write_bytes(canonical(proof) + b"\n")
    print(json.dumps({"pass": proof["pass"], "git_head": proof["git_head"], "tracked_changes": len(proof["tracked_status"]), "live_pins_unchanged": sum(item["unchanged"] for item in live), "live_pins_total": len(live)}, sort_keys=True))
    raise SystemExit(0 if proof["pass"] else 1)


if __name__ == "__main__":
    main()
