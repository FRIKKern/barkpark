#!/usr/bin/env python3
"""Re-land advisory: does this PR touch files a recently-closed task already landed?

Task-obsession layer 3 (the CI half). Given a PR's changed files and the ledger's
closed tasks (each carrying a `content.landed.files` digest written at close), it
flags closed tasks whose landed files overlap the PR — a hint that the change may
be re-doing or colliding with work that already shipped. ADVISORY only: it emits
findings, never blocks a merge (reverts and follow-ups legitimately touch the
same files).

Two calibrated dampers keep the signal readable:

  * Hot-file down-weighting — files that appear in a large fraction of digests
    (the capabilities manifest, router, shared test helpers) carry no signal;
    they're excluded from overlap. Derived by FREQUENCY (self-adjusting) plus a
    static seed list, so the check needs no hand-maintained ignore file.

  * Dependency-edge suppression — a finding against a task the PR's own task
    DEPENDS ON is suppressed: a revert/follow-up is expected to touch the same
    files, and the edge already records that intent.

Usage:
  python3 reland_check.py --files changed.txt --tasks tasks.json \
    [--pr-task <id>] [--dep <id> ...] [--min-overlap 1] [--hot-frac 0.4]
  (changed.txt: one path per line; tasks.json: `bp task ls -o json` output)
"""
import argparse
import json
import sys
from collections import Counter

# Files that are load-bearing for almost every change — always hot regardless of
# frequency (a small backlog might not reach the frequency threshold yet).
SEED_HOT = {
    "api/lib/barkpark_web/router.ex",
    "api/test/support/data_case.ex",
    "api/test/support/tenancy_fixtures.ex",
}


def load_files(path):
    with open(path) as f:
        return {line.strip() for line in f if line.strip()}


def extract_docs(raw):
    """Tolerate every task-list shape: `bp task ls` ({docs:[...]}), the public
    query endpoint ({result:{documents:[...]}}), a bare list, etc."""
    if isinstance(raw, list):
        return raw
    if not isinstance(raw, dict):
        return []
    for key in ("docs", "documents", "rows", "data"):
        if isinstance(raw.get(key), list):
            return raw[key]
    r = raw.get("result")
    if isinstance(r, list):
        return r
    if isinstance(r, dict):
        return extract_docs(r)
    return []


def landed_files(task):
    c = task.get("content") or {}
    landed = c.get("landed") or task.get("landed") or {}
    files = landed.get("files") if isinstance(landed, dict) else None
    return {str(x) for x in files} if isinstance(files, list) else set()


def norm_id(x):
    return (x or "").removeprefix("drafts.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", required=True, help="PR changed files, one per line")
    ap.add_argument("--tasks", required=True, help="bp task ls -o json")
    ap.add_argument("--pr-task", default="", help="the PR's own task id (for edge suppression)")
    ap.add_argument("--dep", action="append", default=[], help="a task id the PR's task depends on")
    ap.add_argument("--min-overlap", type=int, default=1, help="min shared non-hot files to flag")
    ap.add_argument("--hot-frac", type=float, default=0.4, help="digest fraction that makes a file hot")
    ap.add_argument("--out", default="", help="write findings JSON here (else stdout)")
    args = ap.parse_args()

    pr_files = load_files(args.files)
    docs = extract_docs(json.load(open(args.tasks)))

    # Closed tasks that carry a land digest.
    digests = []
    for t in docs:
        c = t.get("content") or {}
        lifecycle = c.get("lifecycle_status") or t.get("lifecycle_status")
        files = landed_files(t)
        if lifecycle in ("done",) and files:
            digests.append({"id": norm_id(t.get("doc_id") or t.get("_id")), "files": files})

    # Frequency-derived hot files: appear in >= hot_frac of digests (min 3 digests
    # before frequency is trusted) — plus the seed list.
    freq = Counter(f for d in digests for f in d["files"])
    n = len(digests)
    hot = set(SEED_HOT)
    if n >= 3:
        hot |= {f for f, c in freq.items() if c / n >= args.hot_frac}

    suppressed = {norm_id(x) for x in args.dep}
    pr_task = norm_id(args.pr_task)

    findings = []
    for d in digests:
        if d["id"] == pr_task or d["id"] in suppressed:
            continue
        overlap = (d["files"] & pr_files) - hot
        if len(overlap) >= args.min_overlap:
            findings.append({
                "task": d["id"],
                "overlap": sorted(overlap),
                "hot_excluded": sorted((d["files"] & pr_files) & hot),
            })

    findings.sort(key=lambda f: len(f["overlap"]), reverse=True)
    result = {
        "pr_files": len(pr_files),
        "digests_scanned": n,
        "hot_files": sorted(hot),
        "findings": findings,
    }

    out = json.dumps(result, indent=1)
    if args.out:
        open(args.out, "w").write(out)
    else:
        print(out)

    # Machine line for the workflow to key on.
    print(f"RELAND_FINDINGS={len(findings)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
