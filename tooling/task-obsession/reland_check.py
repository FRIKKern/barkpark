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

ADVISORY IS NOT THE SAME AS SILENT. "0 findings" has three utterly different
causes and the check used to print the same green for all of them: a real clean
scan, an HTTP error envelope read as an empty ledger, and a healthy scan of a
ledger where NO task carries a land digest at all. So every run now prints a
tri-state classification FIRST — `RELAND_STATUS=ok|infra|skipped` — and the
caller is expected to read the status before it reads `RELAND_FINDINGS`:

  ok      — the payload was a task list and was scanned.
  infra   — the payload is an error envelope / unparseable / carries no
            documents list. Nothing was scanned; findings are meaningless.
  skipped — the fetcher deliberately did not evaluate (see reland_fetch.py).

`RELAND_ZERO_DIGEST=1` marks the third case: docs were scanned but not one
carried a `content.landed` digest, so a 0-finding verdict is hollow. (The
root cause of the live zero-digest corpus is tracked separately as
`arpss-reland-check-zero-landed-signal`.)

`--strict` (for CI) turns an `infra` payload into a distinct exit code 2 so a
misconfigured pipeline cannot be mistaken for a clean one; without it the local
`bp task ls` path stays tolerant and exits 0.

Usage:
  python3 reland_check.py --files changed.txt --tasks tasks.json \
    [--pr-task <id>] [--dep <id> ...] [--min-overlap 1] [--hot-frac 0.4] [--strict]
  (changed.txt: one path per line; tasks.json: `bp task ls -o json` output, a
   raw query envelope, or a `reland_fetch.py` artifact)
"""
import argparse
import json
import sys
from collections import Counter

STATUS_OK = "ok"
STATUS_INFRA = "infra"
STATUS_SKIPPED = "skipped"
EXIT_INFRA = 2

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


def find_docs(raw):
    """The task list inside any known payload shape, or None if there ISN'T one.

    None and [] are different answers and the whole loud-fail rests on the
    distinction: `[]` is an empty ledger, `None` is a payload that never carried
    a ledger (an error envelope, an HTML error page, a truncated body)."""
    if isinstance(raw, list):
        return raw
    if not isinstance(raw, dict):
        return None
    for key in ("docs", "documents", "rows", "data"):
        if isinstance(raw.get(key), list):
            return raw[key]
    r = raw.get("result")
    if r is not None:
        return find_docs(r)
    return None


def extract_docs(raw):
    """Tolerate every task-list shape: `bp task ls` ({docs:[...]}), the public
    query endpoint ({result:{documents:[...]}}), a bare list, etc."""
    docs = find_docs(raw)
    return docs if docs is not None else []


def why_not_a_ledger(raw):
    """A human-readable reason a payload carries no task list."""
    if isinstance(raw, dict) and isinstance(raw.get("error"), dict):
        err = raw["error"]
        return "error envelope code=%s message=%s" % (err.get("code"), err.get("message"))
    if isinstance(raw, dict) and raw.get("error") is not None:
        return "error envelope: %s" % (raw["error"],)
    if isinstance(raw, dict):
        return "no documents list in payload (top level: %s)" % (sorted(raw.keys())[:6],)
    return "payload is a %s, not an object or a list" % type(raw).__name__


def classify(raw):
    """(docs, status, meta, note) — the verdict that precedes every finding.

    A `reland_fetch.py` artifact carries its OWN verdict under `reland_fetch`
    (it saw the HTTP status code, which this side never can); that verdict wins,
    so an `infra`/`skipped` fetch can never be re-read here as a clean scan."""
    meta = raw.get("reland_fetch") if isinstance(raw, dict) else None
    meta = meta if isinstance(meta, dict) else {}
    docs = find_docs(raw)

    if meta.get("status") in (STATUS_INFRA, STATUS_SKIPPED):
        note = str(meta.get("note") or "the fetch step reported %s" % meta["status"])
        return docs or [], meta["status"], meta, note
    if docs is None:
        return [], STATUS_INFRA, meta, why_not_a_ledger(raw)
    return docs, STATUS_OK, meta, str(meta.get("note") or "")


def load_tasks(path):
    """(docs, status, meta, note) — an unparseable file is `infra`, never a crash."""
    try:
        with open(path) as f:
            raw = json.load(f)
    except FileNotFoundError:
        return [], STATUS_INFRA, {}, "tasks file %s does not exist" % path
    except json.JSONDecodeError as e:
        return [], STATUS_INFRA, {}, "tasks file %s is not JSON (%s)" % (path, e)
    return classify(raw)


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
    ap.add_argument(
        "--strict",
        action="store_true",
        help="CI: exit %d on an infra/skipped payload instead of reporting a clean scan" % EXIT_INFRA,
    )
    args = ap.parse_args()

    pr_files = load_files(args.files)
    docs, status, meta, note = load_tasks(args.tasks)

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

    # A payload that never carried a ledger scanned nothing — its findings are
    # not "none", they are unknown. Never let them read as a clean scan.
    if status != STATUS_OK:
        findings = []

    # Scanned real documents but not one carried a land digest: a 0-finding
    # verdict here is hollow, not clean.
    zero_digest = bool(status == STATUS_OK and len(docs) > 0 and n == 0)

    result = {
        "status": status,
        "note": note,
        "pr_files": len(pr_files),
        "docs_scanned": len(docs),
        "digests_scanned": n,
        "zero_digest": zero_digest,
        "pages": meta.get("pages"),
        "total": meta.get("total"),
        "truncated": bool(meta.get("truncated")),
        "auth": meta.get("auth"),
        "hot_files": sorted(hot),
        "findings": findings,
    }

    out = json.dumps(result, indent=1)
    if args.out:
        open(args.out, "w").write(out)
    else:
        print(out)

    # Machine lines for the workflow to key on — STATUS first, deliberately:
    # nothing downstream may read FINDINGS without having read STATUS.
    print(f"RELAND_STATUS={status}", file=sys.stderr)
    print(f"RELAND_DOCS_SCANNED={len(docs)}", file=sys.stderr)
    print(f"RELAND_DIGESTS_SCANNED={n}", file=sys.stderr)
    print(f"RELAND_ZERO_DIGEST={1 if zero_digest else 0}", file=sys.stderr)
    print(f"RELAND_PAGES={meta.get('pages', '')}", file=sys.stderr)
    print(f"RELAND_TRUNCATED={1 if result['truncated'] else 0}", file=sys.stderr)
    print(f"RELAND_AUTH={meta.get('auth', '')}", file=sys.stderr)
    print(f"RELAND_NOTE={note}", file=sys.stderr)
    print(f"RELAND_FINDINGS={len(findings)}", file=sys.stderr)

    # `skipped` is a deliberate non-evaluation (a fork with no secret), not a
    # broken pipeline — only `infra` earns the distinct exit code.
    if args.strict and status == STATUS_INFRA:
        return EXIT_INFRA
    return 0


if __name__ == "__main__":
    sys.exit(main())
