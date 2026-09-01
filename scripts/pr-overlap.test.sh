#!/usr/bin/env bash
#
# pr-overlap.test.sh — the harness for the overlap map and, above all, for its
# refusals.
#
# FULLY HERMETIC. The analysis path is driven with --from-json captures; the
# fetch path is driven with a `gh` stub on PATH. Nothing reaches the network.
#
# THE CASES THIS FILE EXISTS FOR are the failure ones. An overlap map has a
# uniquely nasty degenerate output: a map built from a failed gh call is EMPTY,
# and an empty map is indistinguishable from "no PRs conflict" — a green light
# manufactured by a broken instrument. Cases 8-11 prove that every gh failure
# exits 2 with a HOLD and prints NO map at all, and case 6 proves a genuine
# zero says so in words so the two can never be confused.
#
#   scripts/pr-overlap.test.sh

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/pr-overlap.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pr-overlap-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "-- $* --"; }

# D37: never read the status of `producer | grep -q`. Here-strings only.
has() { grep -qF -- "$2" <<<"$1"; }

BIN="$TMP/bin"; mkdir -p "$BIN"

# run <args...> — stdout and stderr are captured SEPARATELY, because the whole
# HOLD contract is "loud on stderr, nothing on stdout".
run() {
  OUT="$("$SCRIPT" "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}

cap() { printf '%s\n' "$2" > "$TMP/$1.json"; printf '%s\n' "$TMP/$1.json"; }

echo "== pr-overlap.sh — the map, and the refusal to print a fake one =="

# ═══ fixtures ═══════════════════════════════════════════════════════════════

DISJOINT="$(cap disjoint '[
 {"number":1,"title":"a","headRefName":"ba","mergeable":"MERGEABLE","files":[{"path":"x.ex"}]},
 {"number":2,"title":"b","headRefName":"bb","mergeable":"MERGEABLE","files":[{"path":"y.ex"}]}
]')"

TANGLED="$(cap tangled '[
 {"number":101,"title":"alpha","headRefName":"br-alpha","mergeable":"MERGEABLE","files":[{"path":"a.ex"},{"path":"b.ex"}]},
 {"number":102,"title":"beta","headRefName":"br-beta","mergeable":"CONFLICTING","files":[{"path":"b.ex"},{"path":"c.ex"}]},
 {"number":103,"title":"gamma","headRefName":"br-gamma","mergeable":"MERGEABLE","files":[{"path":"b.ex"}]},
 {"number":104,"title":"delta","headRefName":"br-delta","mergeable":"MERGEABLE","files":[{"path":"z.ex"}]}
]')"

TWO_ONLY="$(cap twoonly '[
 {"number":7,"title":"a","headRefName":"b7","mergeable":"MERGEABLE","files":[{"path":"shared.ex"}]},
 {"number":8,"title":"b","headRefName":"b8","mergeable":"MERGEABLE","files":[{"path":"shared.ex"}]}
]')"

EMPTY="$(cap empty '[]')"
GARBAGE="$TMP/garbage.json"; printf 'not json at all\n' > "$GARBAGE"

# ═══ usage ══════════════════════════════════════════════════════════════════

section "1  usage errors exit 2"
run --frobnicate
if [ "$RC" = 2 ]; then ok "1a unknown flag -> exit 2"; else bad "1a got exit $RC"; fi
run -o yaml --from-json "$DISJOINT"
if [ "$RC" = 2 ]; then ok "1b unknown -o format -> exit 2"; else bad "1b got exit $RC"; fi
run --limit abc
if [ "$RC" = 2 ]; then ok "1c non-numeric --limit -> exit 2"; else bad "1c got exit $RC"; fi
run --from-json "$TMP/nope.json"
if [ "$RC" = 2 ]; then ok "1d missing capture file -> exit 2"; else bad "1d got exit $RC"; fi
run --help
if [ "$RC" = 0 ]; then ok "1e --help -> exit 0"; else bad "1e got exit $RC"; fi

# ═══ the analysis ═══════════════════════════════════════════════════════════

section "2  disjoint PRs report no pairs, in words"
run --from-json "$DISJOINT"
if [ "$RC" = 0 ]; then ok "2a exit 0"; else bad "2a got exit $RC"; fi
if has "$OUT" "2 open PR(s), 0 overlapping pair(s)"; then
  ok "2b header counts the PRs it actually read"
else
  bad "2b header: $(head -1 <<<"$OUT")"
fi
if has "$OUT" "every open PR touches a disjoint file set"; then
  ok "2c a real 'no overlaps' is spelled out"
else
  bad "2c no explicit disjoint statement"
fi

section "3  overlapping pairs are named with their shared paths"
run --from-json "$TANGLED"
if has "$OUT" "#101 <-> #102: 1 shared file(s)"; then
  ok "3a pair line uses the '#A <-> #B: N shared files' shape"
else
  bad "3a no pair line in the expected shape"
fi
if has "$OUT" "      b.ex"; then ok "3b the shared path itself is printed"; else bad "3b shared path missing"; fi
if has "$OUT" "4 open PR(s), 3 overlapping pair(s), 1 hotspot file(s)"; then
  ok "3c the pair count is right (101/102, 101/103, 102/103)"
else
  bad "3c header: $(head -1 <<<"$OUT")"
fi

section "4  HOTSPOT is 3+ PRs, and 2 PRs is NOT a hotspot"
if has "$OUT" "HOTSPOT  b.ex"; then ok "4a b.ex (3 PRs) is flagged HOTSPOT"; else bad "4a b.ex not flagged"; fi
if has "$OUT" "3 PRs: #101 #102 #103"; then ok "4b the hotspot names its PRs"; else bad "4b hotspot PR list missing"; fi
run --from-json "$TWO_ONLY"
if has "$OUT" "0 hotspot file(s)"; then
  ok "4c a file shared by exactly 2 PRs is NOT a hotspot (boundary holds)"
else
  bad "4c the 3+ boundary is wrong — 2 PRs produced a hotspot"
fi
if has "$OUT" "#7 <-> #8: 1 shared file(s)"; then
  ok "4d ... but it IS still reported as an overlapping pair"
else
  bad "4d the 2-PR overlap went unreported"
fi

section "5  merge order puts the zero-degree PR first"
run --from-json "$TANGLED"
ORDER_LINE="$(grep -A1 'SUGGESTED MERGE ORDER' <<<"$OUT" | tail -1)"
if has "$ORDER_LINE" "#104"; then
  ok "5a #104 (degree 0) is first: '$ORDER_LINE'"
else
  bad "5a first in order was: '$ORDER_LINE'"
fi
if has "$ORDER_LINE" "degree 0"; then ok "5b the degree is shown"; else bad "5b no degree column"; fi

section "6  a genuine zero says so IN WORDS, so it cannot pass for a failure"
run --from-json "$EMPTY"
if [ "$RC" = 0 ]; then ok "6a zero open PRs -> exit 0"; else bad "6a got exit $RC"; fi
if has "$OUT" "That is a real zero, not a failed read"; then
  ok "6b an empty map is explicitly distinguished from a HOLD"
else
  bad "6b an empty map printed nothing to distinguish it from a failed read"
fi

section "7  -o json is machine-readable and carries the same analysis"
run -o json --from-json "$TANGLED"
if [ "$RC" = 0 ]; then ok "7a exit 0"; else bad "7a got exit $RC"; fi
JQ_OUT="$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["open_prs"], d["overlapping_pairs"], d["hotspot_files"],
      d["merge_order"][0]["number"], d["hotspots"][0]["file"],
      len(d["pairs"]))
' 2>/dev/null || echo PARSE_FAILED)"
if [ "$JQ_OUT" = "4 3 1 104 b.ex 3" ]; then
  ok "7b json parses and matches the table: $JQ_OUT"
else
  bad "7b json analysis was '$JQ_OUT' (want '4 3 1 104 b.ex 3')"
fi

# ═══ the refusals — the reason this harness exists ══════════════════════════

section "8  an unparsable capture is a HOLD, not an empty map"
run --from-json "$GARBAGE"
if [ "$RC" = 2 ]; then ok "8a garbage payload -> exit 2"; else bad "8a got exit $RC (want 2)"; fi
if has "$ERR" "HOLD: the PR payload is not JSON"; then
  ok "8b says HOLD on stderr"
else
  bad "8b no HOLD on stderr"
fi
if ! has "$OUT" "PR OVERLAP MAP"; then
  ok "8c printed NO map"
else
  bad "8c printed a map built from an unparsable read"
fi

# ── the gh stub, for the fetch path ─────────────────────────────────────────
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  if [ -f "$STUB/list.fail" ]; then
    echo "error: You have exceeded a secondary rate limit" >&2
    exit 1
  fi
  cat "$STUB/list.json"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ -f "$STUB/view-$3.fail" ]; then
    echo "error: HTTP 403: API rate limit exceeded" >&2
    exit 1
  fi
  cat "$STUB/view-$3.json"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"

STUB="$TMP/ghworld"; mkdir -p "$STUB"; export STUB
printf '[{"number":1},{"number":2}]\n' > "$STUB/list.json"
printf '{"number":1,"title":"a","headRefName":"b1","mergeable":"MERGEABLE","files":[{"path":"s.ex"}]}\n' > "$STUB/view-1.json"
printf '{"number":2,"title":"b","headRefName":"b2","mergeable":"MERGEABLE","files":[{"path":"s.ex"}]}\n' > "$STUB/view-2.json"

OLDPATH="$PATH"
export PATH="$BIN:$PATH"

section "9  the gh fetch path assembles a map from pr list + pr view"
run
if [ "$RC" = 0 ]; then ok "9a exit 0"; else bad "9a got exit $RC; stderr: $ERR"; fi
if has "$OUT" "#1 <-> #2: 1 shared file(s)"; then
  ok "9b the fetched PRs are analysed identically to a capture"
else
  bad "9b fetched analysis wrong: $OUT"
fi

section "10 gh pr list FAILING is a HOLD with no map — the vacuous-green case"
touch "$STUB/list.fail"
run
if [ "$RC" = 2 ]; then ok "10a exit 2"; else bad "10a got exit $RC (want 2)"; fi
if has "$ERR" "HOLD — pr-overlap.sh could not read GitHub."; then
  ok "10b loud HOLD on stderr"
else
  bad "10b no HOLD banner"
fi
if has "$ERR" "secondary rate limit"; then
  ok "10c gh's own refusal text is quoted, not swallowed"
else
  bad "10c gh's message was swallowed"
fi
if [ -z "$OUT" ]; then
  ok "10d stdout is EMPTY — no map that could be read as 'no overlaps'"
else
  bad "10d printed to stdout on a failed read: $OUT"
fi
rm -f "$STUB/list.fail"

section "11 a gh pr view failing PART-WAY is also a HOLD, not a partial map"
touch "$STUB/view-2.fail"
run
if [ "$RC" = 2 ]; then ok "11a exit 2"; else bad "11a got exit $RC (want 2)"; fi
if [ -z "$OUT" ]; then
  ok "11b no PARTIAL map printed — a partial map understates every overlap"
else
  bad "11b printed a partial map: $OUT"
fi
if has "$ERR" "gh pr view 2 failed"; then
  ok "11c names WHICH call failed"
else
  bad "11c did not name the failing call"
fi
rm -f "$STUB/view-2.fail"

section "12 gh missing from PATH is a HOLD, never a silent empty map"
# A PATH with bash + basename + python3 and deliberately NO gh. Only the child
# gets it: emptying the harness's own PATH would just break the harness.
SAFE="$TMP/nogh"; mkdir -p "$SAFE"
for t in bash basename python3; do
  ln -sf "$(command -v "$t")" "$SAFE/$t"
done
OUT="$(PATH="$SAFE" "$SCRIPT" 2>"$TMP/err")"
RC=$?
ERR="$(cat "$TMP/err")"
if [ "$RC" = 2 ]; then ok "12a exit 2"; else bad "12a got exit $RC (want 2)"; fi
if has "$ERR" "gh is not on PATH"; then ok "12b names the missing tool"; else bad "12b: $ERR"; fi
if [ -z "$OUT" ]; then ok "12c still no map on stdout"; else bad "12c printed a map: $OUT"; fi
export PATH="$OLDPATH"

echo
echo "pr-overlap.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
