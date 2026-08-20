#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scaffy-mine — the CANONICAL, reproducible frequency miner for the Scaffy epic.
#
# Scaffy's premise is "commands as content": a `.scaffy` command CREATEs a
# vertical slice and injects wiring into accretion files (registries, routers,
# barrels, error maps) at guarded anchors. W5 justified the catalog by mining
# git history BY HAND, agent-side, and cited numbers (38 error clauses, 739
# router partners, 234/303 co-creations). Some of those figures were computed
# with a drifting `--since='12 months ago'` window and a capped node script that
# cannot be re-run. This script REPLACES that: one read-only git pass, a window
# PINNED to a commit, no caps, no derived-artifact gate. Its output IS canon.
#
# It is the executable prototype for `bp scaffy discover` (leap 1). See README.md
# for the Go-pass spec. Do NOT build the Go subcommand here (backlog:
# scaffy-backlog-discover-go-pass).
#
# ── Guarantees ───────────────────────────────────────────────────────────────
#   • READ-ONLY. Only `git log` / `git rev-parse` / `git show -s`. Never writes
#     the repo, never touches _build/, deps/, or any source. Safe on any checkout.
#   • DETERMINISTIC. The window is derived from the PIN commit's own commit date,
#     not from wall-clock "now", so the same checkout yields the same JSON on any
#     day. (A drifting `--since=12 months ago` is exactly the W5 irreproducibility.)
#   • DEPENDENCY-FREE. bash + git + awk only. `node` is used ONLY to read the
#     optional derived nodes.json universe, and its absence degrades to `null`,
#     never an error.
#
# ── The PIN and the window ───────────────────────────────────────────────────
#   PIN     = 591fdcd53  ("fix(scaffy): refresh the D30 corpus census …", #3912)
#   WINDOW  = commits reachable from PIN, authored within 12 calendar months
#             before the PIN's commit day, --no-merges.
#
# ── Documented exclusions (what the counts deliberately DROP) ─────────────────
#   • Merge commits (--no-merges): a merge re-touches every file on the branch and
#     is noise, not authorship. This matches cochange.mjs.
#   • Commits OUTSIDE the 12-month pre-PIN window (older accretion is stale signal).
#   • Commits AFTER the PIN (reachability is limited to `$PIN`), so re-running on a
#     newer checkout does not move the numbers.
#   • For co-creation: only files with git status ADDED count (a chore that ADDS a
#     new `.ex` beside a new `_test.exs` — not edits to existing pairs).
#   • The 739 router-partner figure from W5 is DROPPED entirely — irreproducible
#     under the capped cochange.mjs (MAX_PARTNERS=8) and its 2874-commit window is
#     unreconstructable. See README.md §Honesty record.
#
# GATE: `bash tooling/scaffy-mine/mine.sh` — exits 0, emits one JSON object, <60s.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PIN="591fdcd53"
ERRORS="api/lib/barkpark/content/errors.ex"
ROUTER="api/lib/barkpark_web/router.ex"
UNIVERSE_JSON="tooling/barkpark-sync/nodes.json"

# Run from the repo root regardless of caller CWD (read-only; never cd's the tree).
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# ── Fail loudly if the pin is not in this checkout ───────────────────────────
if ! git cat-file -e "${PIN}^{commit}" 2>/dev/null; then
  echo "scaffy-mine: PIN ${PIN} not found in this repository." >&2
  exit 3
fi

# ── Derive the 12-month-before-pin window date (BSD date, GNU fallback) ───────
PIN_ISO="$(git show -s --format=%cI "$PIN")"          # 2026-07-17T09:24:05+02:00
PIN_DAY="${PIN_ISO%%T*}"                              # 2026-07-17
SINCE="$(date -j -v-12m -f '%Y-%m-%d' "$PIN_DAY" '+%Y-%m-%d' 2>/dev/null \
  || date -d "$PIN_DAY -12 months" '+%Y-%m-%d' 2>/dev/null || true)"
if [ -z "${SINCE:-}" ]; then
  echo "scaffy-mine: could not compute the 12-month window (need BSD or GNU date)." >&2
  exit 4
fi

# ── Stage 1 — accretion clause-adds on a single hunk file (errors.ex) ────────
# The added-clause counter: how many `defp build(` clause-lines were ADDED, and
# across how many distinct commits. Also proves the mis-grep: the file's grammar
# is `defp build(` (private); `def build(` returns 0 and would silently under-count.
read -r ERR_ADDED ERR_COMMITS ERR_MISGREP <<EOF
$(git log --no-merges --since="$SINCE" --format='@@C@@%H' -p "$PIN" -- "$ERRORS" | awk '
  /^@@C@@/            { if(np && chit) commits++; chit=0; np=1; next }
  /^\+[ \t]*defp build\(/ { added++;   chit=1; next }
  /^\+[ \t]*def build\(/  { misgrep++;        next }
  END { if(np && chit) commits++; printf "%d %d %d\n", added+0, commits+0, misgrep+0 }')
EOF

# ── Stage 2 — one shared name-status pass → co-creation + router matrix ──────
# The suffix-pair matcher (co-creation) and the uncapped co-change matrix (router)
# ride ONE git-log pass, exactly the shared skeleton the Go pass will use. No caps,
# no universe gate, no support threshold applied at the source.
MATRIX="$(git log --no-merges --since="$SINCE" --format='@@C@@%H' --name-status "$PIN" | awk -v R="$ROUTER" '
  /^@@C@@/ { if(np) flush(); delete addf; na=0; delete allf; nl=0; np=1; next }
  /^[AMDRCT]/ {
    # name-status lines: "STATUS\tPATH"  (renames: "R100\tOLD\tNEW" → take NEW)
    st=$1; path=$NF; allf[nl++]=path
    if(substr(st,1,1)=="A") addf[na++]=path
    next
  }
  function flush(   i,f,x,has,hasex,hastest) {
    # router co-change matrix, over ALL touched files in the commit
    has=0; for(i=0;i<nl;i++) if(allf[i]==R) has=1
    if(has){ rcommits++; for(i=0;i<nl;i++) if(allf[i]!=R) sup[allf[i]]++ }
    # co-creation, over ADDED files only
    hasex=0; hastest=0; delete b; delete t
    for(i=0;i<na;i++){ f=addf[i]
      if(f ~ /_test\.exs$/){ hastest=1; x=f; sub(/_test\.exs$/,"",x); sub(/.*\//,"",x); t[x]=1 }
      else if(f ~ /\.ex$/) { hasex=1;  x=f; sub(/\.ex$/,"",x);       sub(/.*\//,"",x); b[x]=1 }
    }
    if(hasex && hastest) loose++
    for(x in b) if(x in t){ strict++; break }   # commit counts once if any basename pairs
  }
  END {
    if(np) flush()
    naive=0; for(k in sup) naive++
    s2=0; s3=0; s4=0; s5=0
    for(k in sup){ v=sup[k]; if(v>=2)s2++; if(v>=3)s3++; if(v>=4)s4++; if(v>=5)s5++ }
    printf "%d %d %d %d %d %d %d %d\n", loose+0, strict+0, rcommits+0, naive+0, s2, s3, s4, s5
  }')"
read -r COCREATE_LOOSE COCREATE_STRICT ROUTER_COMMITS ROUTER_NAIVE R2 R3 R4 R5 <<EOF
$MATRIX
EOF

# ── Stage 2b — the OPTIONAL nodes.json-universe restriction ───────────────────
# The W5 "~468" figure restricted router partners to the code universe in the
# derived nodes.json (generate.mjs output). That file is GITIGNORED — absent in a
# clean checkout — so this figure is NOT reproducible from source alone. We emit
# it only when the artifact happens to be present, else `null` with a reason.
ROUTER_UNIVERSE="null"
UNIVERSE_NOTE="tooling/barkpark-sync/nodes.json absent (derived/gitignored) — run generate.mjs to materialize; not reproducible from a clean checkout"
if [ -f "$UNIVERSE_JSON" ] && command -v node >/dev/null 2>&1; then
  ROUTER_UNIVERSE="$(
    git log --no-merges --since="$SINCE" --format='@@C@@%H' --name-status "$PIN" \
    | awk -v R="$ROUTER" '
        /^@@C@@/ { if(np) flush(); delete allf; nl=0; np=1; next }
        /^[AMDRCT]/ { allf[nl++]=$NF; next }
        function flush(   i,has){ has=0; for(i=0;i<nl;i++) if(allf[i]==R) has=1
          if(has) for(i=0;i<nl;i++) if(allf[i]!=R) print allf[i] }
        END{ if(np) flush() }' | sort -u \
    | node -e '
        const fs=require("fs");
        const doc=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        const uni=new Set((doc.nodes||[]).filter(n=>n.kind!=="intention"&&n.path).map(n=>n.path));
        let n=0; for(const l of fs.readFileSync(0,"utf8").split("\n")) if(l && uni.has(l)) n++;
        process.stdout.write(String(n));
      ' "$UNIVERSE_JSON"
  )"
  UNIVERSE_NOTE="restricted to code nodes in ${UNIVERSE_JSON} (kind!=intention)"
fi

GEN_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── Emit ONE JSON object ─────────────────────────────────────────────────────
cat <<JSON
{
  "tool": "scaffy-mine",
  "canonical": true,
  "pin": "${PIN}",
  "window": {
    "since": "${SINCE}",
    "until_commit": "${PIN}",
    "pin_commit_day": "${PIN_DAY}",
    "no_merges": true,
    "derivation": "12 calendar months before the PIN commit day; deterministic, not wall-clock relative"
  },
  "errors_ex_accretion": {
    "file": "${ERRORS}",
    "grammar": "defp build(",
    "added_clause_lines": ${ERR_ADDED},
    "distinct_commits": ${ERR_COMMITS},
    "misgrep_def_build": ${ERR_MISGREP},
    "misgrep_note": "'def build(' (public) is the WRONG grep for this file and returns 0; the real clauses are 'defp build(' (private)"
  },
  "co_creation": {
    "definition": "commits (git status ADDED) creating .ex source alongside _test.exs in the same commit",
    "strict_basename_paired": ${COCREATE_STRICT},
    "loose_any_ex_any_test": ${COCREATE_LOOSE},
    "canonical_definition": "strict",
    "note": "strict = commits where an added foo.ex has a basename-matched added foo_test.exs; loose = commits adding any .ex AND any _test.exs"
  },
  "router_ex_cochange": {
    "file": "${ROUTER}",
    "commits": ${ROUTER_COMMITS},
    "partners": {
      "naive_uncapped": ${ROUTER_NAIVE},
      "restricted_to_nodes_json_universe": ${ROUTER_UNIVERSE},
      "restricted_note": "${UNIVERSE_NOTE}",
      "by_min_support": { "ge2": ${R2}, "ge3": ${R3}, "ge4": ${R4}, "ge5": ${R5} }
    },
    "note": "uncapped: NO MAX_PARTNERS, NO support threshold at source, NO sprawl cap — the counts cochange.mjs structurally cannot produce"
  },
  "generated_at": "${GEN_AT}"
}
JSON
