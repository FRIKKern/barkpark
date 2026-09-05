#!/usr/bin/env bash
# merge-gate-autostamp-liveness.sh — does the merge-gate autostamp bridge
# ACTUALLY FIRE, end to end?
#
# THE DEFECT THIS EXISTS FOR. `api/lib/barkpark/plugins/github/merge_events.ex`
# stamps a task's `merge_gate:true` criterion when its PR merges. It shipped in
# #5742 on 2026-07-22 with five criteria, ALL of them proven by unit tests on the
# handler. It then never fired — for 29 days, across 39 merge-gated tasks — and
# nothing went red, because no check ever demanded a DELIVERY. The GitHub App is
# subscribed to `issues` only (scripts/github-app-bootstrap.py: default_events),
# so GitHub never sent a `pull_request` event and the handler was never called.
#
# A handler test cannot see that. This can: it asks the LEDGER whether real
# merges produced real bridge writes, and reds when any link in the chain — App
# event subscription, App permission, webhook delivery, signature, route,
# handler, ledger write — is broken. It is deliberately incapable of proving the
# handler; it can only prove the PATH.
#
# THE ORACLE. `content.merge_gate_autostamp.merge_event` with
# `source == "github_merge_event"` is written by exactly ONE code path,
# `Tasks.Close.reconcile_merge_gate/3`, and only after a real merge webhook. It
# cannot be produced by a hand stamp, by `bp task close`, or by the close-time
# autostamp (which writes a different key with verified:false). Its presence is
# therefore proof of a delivery, not proof of prose.
#
# VERDICTS (exit code is the verdict — there is no vacuous pass):
#   0  LIVE          every candidate merge produced a bridge write.
#   1  BROKEN        a candidate merge produced no bridge write. The path is dead.
#   2  INCONCLUSIVE  no candidate merge in the window. NOT a pass: the check had
#                    nothing to certify. Widen --days or wait for a merge.
#   3  UNAVAILABLE   `gh` or `bp` could not answer. Not a verdict about the bridge.
#
# A "candidate" is a merged PR whose body carries exactly ONE `Task:` trailer
# (the handler's own grammar — more than one is `:ambiguous_trailer`, a refusal
# by design) naming a task that carries a `merge_gate:true` criterion. Those are
# precisely the merges the bridge is contracted to stamp.
#
#   scripts/merge-gate-autostamp-liveness.sh [--days N] [--repo owner/name]
#   scripts/merge-gate-autostamp-liveness.sh --fixture <dir>   # offline replay
#
# --fixture <dir> reads <dir>/prs.json (an array of PR objects as `gh pr list`
# returns them) and <dir>/tasks/<doc_id>.json (a task document) instead of the
# network, so both arms of the proof run hermetically in CI.

set -uo pipefail

# Shape before content on every bp read (task-4eb2994a588453d3).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/bp-read.sh"

DAYS=30
REPO="FRIKKern/barkpark"
FIXTURE=""
LIMIT=500

while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --fixture) FIXTURE="$2"; shift 2;;
    --limit) LIMIT="$2"; shift 2;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) echo "unknown arg $1" >&2; exit 3;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. The merged PRs in the window ──────────────────────────────────────────
if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE/prs.json" ] || { echo "UNAVAILABLE: $FIXTURE/prs.json missing" >&2; exit 3; }
  cp "$FIXTURE/prs.json" "$TMP/prs.json"
else
  command -v gh >/dev/null || { echo "UNAVAILABLE: gh not on PATH" >&2; exit 3; }
  gh pr list --repo "$REPO" --state merged --limit "$LIMIT" \
     --json number,mergedAt,body,mergeCommit > "$TMP/prs.json" 2>"$TMP/gh.err"
  if [ $? -ne 0 ]; then
    echo "UNAVAILABLE: gh pr list failed:" >&2; cat "$TMP/gh.err" >&2; exit 3
  fi
fi

# ── 2. Which of them are candidates? (pure; the handler's own trailer grammar) ─
DAYS="$DAYS" python3 - "$TMP/prs.json" > "$TMP/candidates.txt" <<'PY'
import json, os, re, sys
from datetime import datetime, timedelta, timezone

# Byte-for-byte the handler's @trailer_regex (merge_events.ex).
TRAILER = re.compile(r"^\s*task:\s*([a-z0-9][a-z0-9._/-]*)", re.I | re.M)
cutoff = datetime.now(timezone.utc) - timedelta(days=int(os.environ["DAYS"]))

for pr in json.load(open(sys.argv[1])):
    merged = pr.get("mergedAt")
    if not merged:
        continue
    when = datetime.fromisoformat(merged.replace("Z", "+00:00"))
    if when < cutoff:
        continue
    ids = []
    for m in TRAILER.findall(pr.get("body") or ""):
        if m not in ids:
            ids.append(m)
    if len(ids) != 1:          # :no_trailer / :ambiguous_trailer — not contracted
        continue
    mc = pr.get("mergeCommit") or {}
    print("%s\t%s\t%s\t%s" % (pr["number"], ids[0], merged, mc.get("oid") or ""))
PY
[ $? -eq 0 ] || { echo "UNAVAILABLE: could not parse the PR list" >&2; exit 3; }

# A saturated fetch means the window is really "the last $LIMIT merged PRs",
# which may be SHORTER than --days. Say so rather than implying full coverage.
FETCHED=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/prs.json" 2>/dev/null || echo 0)
if [ "$FETCHED" = "$LIMIT" ]; then
  echo "note: fetched $FETCHED PRs = --limit; the window may be narrower than --days $DAYS." >&2
fi

# ── 3. Fetch each referenced task ────────────────────────────────────────────
mkdir -p "$TMP/tasks"
while IFS="$(printf '\t')" read -r num doc_id merged sha; do
  [ -n "${doc_id:-}" ] || continue
  if [ -n "$FIXTURE" ]; then
    if [ -f "$FIXTURE/tasks/$doc_id.json" ]; then
      cp "$FIXTURE/tasks/$doc_id.json" "$TMP/tasks/$doc_id.json"
    fi
  else
    command -v bp >/dev/null || { echo "UNAVAILABLE: bp not on PATH" >&2; exit 3; }
    # CAPTURE, do not pipe. The old form was
    #   bp task get "$doc_id" -o json 2>/dev/null | python3 -c '... s.find("{") ...'
    # and a refusal defeated it TWICE: 2>/dev/null discarded the message, and
    # the error envelope IS a well-formed `{...}`, so the first-brace parser
    # accepted it and wrote it out as if it were a task. The verdict pass below
    # then read `(c.get("merge_gate_autostamp") or {})` off that envelope and
    # scored the row as "never autostamped" — a refusal rendered as a finding.
    if body="$(bp_json task get "$doc_id" -o json)"; then
      printf '%s' "$body" \
        | python3 -c 'import sys,json;s=sys.stdin.read();i=s.find("{");sys.exit(1) if i<0 else print(json.dumps(json.loads(s[i:])))' \
        > "$TMP/tasks/$doc_id.json" || rm -f "$TMP/tasks/$doc_id.json"
    else
      echo "  (skipped $doc_id: bp refused the read — NOT counted as un-autostamped)" >&2
      rm -f "$TMP/tasks/$doc_id.json"
    fi
  fi
done < "$TMP/candidates.txt"

# ── 4. The verdict ───────────────────────────────────────────────────────────
python3 - "$TMP/candidates.txt" "$TMP/tasks" "$DAYS" <<'PY'
import json, os, sys

cand_file, task_dir, days = sys.argv[1], sys.argv[2], sys.argv[3]

rows = []
for line in open(cand_file):
    line = line.rstrip("\n")
    if not line:
        continue
    num, doc_id, merged, sha = (line.split("\t") + ["", "", "", ""])[:4]
    rows.append((num, doc_id, merged, sha))


def content(doc):
    """bp nests the document under `.doc`; a fixture may be the doc itself.

    FAIL CLOSED. An absent `content` is NOT an empty content — reading the
    envelope instead would silently drop the task from the candidate set, and a
    shrinking denominator is how a liveness check turns into a green that cannot
    go red. Return None and let the caller count it as unresolved.
    """
    d = doc.get("doc", doc)
    c = d.get("content")
    return c if isinstance(c, dict) else None


gated, stamped, unstamped, unresolved = [], [], [], []

for num, doc_id, merged, sha in rows:
    path = os.path.join(task_dir, doc_id + ".json")
    if not os.path.exists(path):
        unresolved.append((num, doc_id))
        continue
    try:
        c = content(json.load(open(path)))
    except Exception:
        c = None
    if c is None:
        unresolved.append((num, doc_id))
        continue

    crits = c.get("acceptance_criteria")
    if not isinstance(crits, list):
        continue
    if not any(isinstance(a, dict) and a.get("merge_gate") is True for a in crits):
        continue  # not contracted: the bridge answers :no_marker by design

    gated.append((num, doc_id))

    # THE ORACLE. Written only by Tasks.Close.reconcile_merge_gate/3, only after
    # a real merge webhook. A hand stamp cannot forge it.
    rec = (c.get("merge_gate_autostamp") or {}).get("merge_event") or {}
    if rec.get("source") == "github_merge_event":
        stamped.append((num, doc_id))
    else:
        unstamped.append((num, doc_id, merged, sha))

print("merge-gate autostamp liveness — window: last %s days" % days)
print("  merged PRs with exactly one Task: trailer .... %d" % len(rows))
print("  ... whose task carries merge_gate:true ....... %d  (candidates)" % len(gated))
print("  ... carrying a bridge write (merge_event) .... %d" % len(stamped))
print("  ... carrying NO bridge write ................. %d" % len(unstamped))
if unresolved:
    print("  (%d trailer(s) named a task that did not resolve — not counted either way)"
          % len(unresolved))
print()

if unstamped:
    print("BROKEN — the end-to-end merge-gate autostamp path did not fire.")
    print("Each of these merged with the bridge's exact contract satisfied and the")
    print("ledger shows no bridge write. The handler is not the suspect; the")
    print("DELIVERY is. Check, in order:")
    print("  1. the GitHub App's subscribed events include `pull_request`")
    print("     (scripts/github-app-bootstrap.py default_events sets it at CREATE")
    print("      time only — an already-created App must be edited by hand, and")
    print("      `pull_request` needs the Pull requests: Read permission, which the")
    print("      installation must then re-accept);")
    print("  2. the App's webhook URL points at this instance and recent deliveries")
    print("     show 2xx;")
    print("  3. the instance logs for `merge reconcile failed`.")
    print()
    for num, doc_id, merged, sha in unstamped:
        print("  PR #%-7s merged %s  ->  %s" % (num, merged, doc_id))
        if sha:
            print("             merge commit %s" % sha)
    sys.exit(1)

if not gated:
    print("INCONCLUSIVE — no merged PR in this window was contracted to the bridge,")
    print("so nothing could be certified. This is NOT a pass: an empty corpus proves")
    print("no liveness. Widen --days, or wait for a merge-gated task to land.")
    sys.exit(2)

print("LIVE — every candidate merge in the window produced a bridge write.")
sys.exit(0)
PY
exit $?
