#!/usr/bin/env bash
#
# pr-overlap.sh — the open-PR file-overlap map, and the conflict cascade it
# predicts.
#
# THE PROBLEM IT INSTRUMENTS
#
#   Merging one PR re-bases every other open PR that touches the same files.
#   With 25 agents in flight, the cheapest merge is not the oldest PR or the
#   greenest one — it is the one that breaks fewest others. This prints the
#   shared-file map, names the files several PRs are fighting over, and orders
#   the merges so the collisions come last.
#
# AN INSTRUMENT THAT CANNOT READ MUST SAY HOLD
#
#   gh secondary rate limits fail a call while `gh api rate_limit` still
#   reports thousands of remaining points. A map built from a failed call is
#   EMPTY, and an empty map reads exactly like "no overlaps" — the most
#   dangerous possible false all-clear here. So: ANY failed gh call aborts with
#   a loud HOLD on stderr and exit 2. There is no partial map.
#
# USAGE
#
#   pr-overlap.sh [-o table|json] [--limit N] [--repo <owner/name>]
#   pr-overlap.sh --from-json <file> [-o table|json]
#
#   -o table       (default) the human map
#   -o json        the same analysis as one JSON object
#   --limit N      how many open PRs to read (default 60)
#   --repo         pass through to gh when the cwd is not the repo
#   --from-json    read an already-captured PR array instead of calling gh.
#                  This is the offline/hermetic input the test harness uses,
#                  and it is also how you re-analyse a capture without
#                  re-spending rate-limit budget.
#
#   The expected shape, whether captured or fetched, is a JSON array of
#   {number, title, headRefName, mergeable, files:[{path}]}.
#
# EXIT CODES
#   0  the map was built (zero open PRs is a legitimate 0 — it says so)
#   2  usage error, or HOLD: a gh call failed and the map would have been a lie

set -euo pipefail

PROG="$(basename -- "$0")"

usage() {
  cat <<'EOF'
usage: pr-overlap.sh [-o table|json] [--limit N] [--repo <owner/name>]
       pr-overlap.sh --from-json <file> [-o table|json]

  Open-PR file-overlap map: which PRs share files, which files are HOTSPOTS
  (3+ PRs), and a merge order that minimises the conflict cascade.

  A failed gh call is a loud HOLD on stderr and exit 2 — never an empty map.

exit: 0 map built    2 usage error, or HOLD (gh unreadable)
EOF
}

die_usage() {
  printf '%s: %s\n\n' "$PROG" "$1" >&2
  usage >&2
  exit 2
}

hold() {
  printf '\n' >&2
  printf 'HOLD — pr-overlap.sh could not read GitHub.\n' >&2
  printf '  %s\n' "$1" >&2
  printf '  NOT printing a map. An empty overlap map reads as "no overlaps",\n' >&2
  printf '  which is the one wrong answer this instrument must never give.\n' >&2
  printf '  Likely cause: a gh SECONDARY rate limit, which gh api rate_limit\n' >&2
  printf '  does not report. Wait a minute and re-run, or re-analyse a capture\n' >&2
  printf '  with --from-json.\n' >&2
  exit 2
}

OUT=table
LIMIT=60
REPO=""
FROM_JSON=""

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)
      [ $# -ge 2 ] || die_usage "-o needs a format"
      case "$2" in table|json) OUT="$2" ;; *) die_usage "unknown format: $2" ;; esac
      shift 2 ;;
    --limit)
      [ $# -ge 2 ] || die_usage "--limit needs a number"
      case "$2" in ''|*[!0-9]*) die_usage "--limit must be a number: $2" ;; esac
      LIMIT="$2"; shift 2 ;;
    --repo)
      [ $# -ge 2 ] || die_usage "--repo needs owner/name"
      REPO="$2"; shift 2 ;;
    --from-json)
      [ $# -ge 2 ] || die_usage "--from-json needs a file"
      FROM_JSON="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unexpected argument: $1" ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die_usage "python3 is required for the set analysis"

# ── gather ───────────────────────────────────────────────────────────────────

PR_ARRAY=""

if [ -n "$FROM_JSON" ]; then
  [ -f "$FROM_JSON" ] || die_usage "no such capture: $FROM_JSON"
  PR_ARRAY="$(cat -- "$FROM_JSON")"
else
  command -v gh >/dev/null 2>&1 || hold "gh is not on PATH."

  gh_args=(pr list --state open --limit "$LIMIT" --json number)
  [ -n "$REPO" ] && gh_args+=(--repo "$REPO")
  if ! LIST_JSON="$(gh "${gh_args[@]}" 2>&1)"; then
    hold "gh pr list failed: $(printf '%s' "$LIST_JSON" | head -3 | tr '\n' ' ')"
  fi

  NUMBERS="$(grep -oE '"number":[0-9]+' <<<"$LIST_JSON" | cut -d: -f2 | sort -un || true)"

  PARTS=""
  if [ -n "$NUMBERS" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      view_args=(pr view "$n" --json "number,title,headRefName,files,mergeable")
      [ -n "$REPO" ] && view_args+=(--repo "$REPO")
      if ! ONE="$(gh "${view_args[@]}" 2>&1)"; then
        hold "gh pr view $n failed: $(printf '%s' "$ONE" | head -3 | tr '\n' ' ')"
      fi
      if [ -z "$PARTS" ]; then PARTS="$ONE"; else PARTS="$PARTS,$ONE"; fi
    done <<<"$NUMBERS"
  fi
  PR_ARRAY="[$PARTS]"
fi

# ── analyse ──────────────────────────────────────────────────────────────────
#
# The set math lives in python3 because bash has no sets, and a hand-rolled
# pairwise intersection in awk is exactly the kind of thing that silently
# reports zero. Input is the PR array on stdin; output is the finished report.

printf '%s' "$PR_ARRAY" | OUT="$OUT" python3 -c '
import json, os, sys
from itertools import combinations

raw = sys.stdin.read().strip()
try:
    prs = json.loads(raw) if raw else []
except json.JSONDecodeError as e:
    sys.stderr.write("HOLD: the PR payload is not JSON (%s).\n" % e)
    sys.stderr.write("      Refusing to print a map built from an unparsable read.\n")
    sys.exit(2)

if isinstance(prs, dict):
    prs = [prs]

norm = []
for p in prs:
    files = sorted({f.get("path") for f in (p.get("files") or []) if f.get("path")})
    norm.append({
        "number": p.get("number"),
        "title": p.get("title") or "",
        "headRefName": p.get("headRefName") or "",
        "mergeable": p.get("mergeable") or "UNKNOWN",
        "files": files,
    })
norm.sort(key=lambda p: (p["number"] is None, p["number"]))

byfile = {}
for p in norm:
    for f in p["files"]:
        byfile.setdefault(f, []).append(p["number"])

pairs = []
degree = {p["number"]: 0 for p in norm}
shared_count = {p["number"]: 0 for p in norm}
for a, b in combinations(norm, 2):
    shared = sorted(set(a["files"]) & set(b["files"]))
    if not shared:
        continue
    pairs.append({"a": a["number"], "b": b["number"], "shared": shared})
    degree[a["number"]] += 1
    degree[b["number"]] += 1
    shared_count[a["number"]] += len(shared)
    shared_count[b["number"]] += len(shared)

hotspots = [
    {"file": f, "prs": sorted(set(ns))}
    for f, ns in sorted(byfile.items())
    if len(set(ns)) >= 3
]
hotspots.sort(key=lambda h: (-len(h["prs"]), h["file"]))

# Fewest collisions first; ties broken by shared-file volume, then PR number,
# so the order is deterministic and reproducible run to run.
order = sorted(
    norm,
    key=lambda p: (degree[p["number"]], shared_count[p["number"]], p["number"] or 0),
)
merge_order = [
    {
        "number": p["number"],
        "degree": degree[p["number"]],
        "shared_files": shared_count[p["number"]],
        "headRefName": p["headRefName"],
        "mergeable": p["mergeable"],
        "title": p["title"],
    }
    for p in order
]

report = {
    "open_prs": len(norm),
    "overlapping_pairs": len(pairs),
    "hotspot_files": len(hotspots),
    "pairs": pairs,
    "hotspots": hotspots,
    "merge_order": merge_order,
}

if os.environ.get("OUT") == "json":
    print(json.dumps(report, indent=2, sort_keys=True))
    sys.exit(0)

w = sys.stdout.write
w("PR OVERLAP MAP — %d open PR(s), %d overlapping pair(s), %d hotspot file(s)\n"
  % (len(norm), len(pairs), len(hotspots)))

if not norm:
    w("\n  0 open PRs were read. That is a real zero, not a failed read:\n")
    w("  a failed gh call exits 2 with a HOLD and prints no map at all.\n")
    sys.exit(0)

w("\nPAIRS (merging either one re-bases the other)\n")
if not pairs:
    w("  (none — every open PR touches a disjoint file set)\n")
for p in sorted(pairs, key=lambda x: (-len(x["shared"]), x["a"], x["b"])):
    w("  #%s <-> #%s: %d shared file(s)\n" % (p["a"], p["b"], len(p["shared"])))
    for f in p["shared"]:
        w("      %s\n" % f)

w("\nHOTSPOTS (a file touched by 3+ open PRs)\n")
if not hotspots:
    w("  (none)\n")
for h in hotspots:
    w("  HOTSPOT  %s\n" % h["file"])
    w("           %d PRs: %s\n" % (len(h["prs"]), " ".join("#%s" % n for n in h["prs"])))

w("\nSUGGESTED MERGE ORDER (fewest collisions first)\n")
for i, m in enumerate(merge_order, 1):
    w("  %2d. #%-6s degree %-3d shared %-4d %-14s %s\n"
      % (i, m["number"], m["degree"], m["shared_files"],
         m["mergeable"], m["headRefName"]))
w("\n  degree = how many other open PRs share at least one file with it.\n")
w("  Merging a PR re-bases every PR below it that shares its files; the\n")
w("  zero-degree ones at the top cost nothing to land.\n")
'
