#!/usr/bin/env bash
# main-verdict-presence.test.sh — the both-ways proofs for the absent-verdict read.
#
# Nothing here asserts "the script ran". Every arm is proven against a fixture
# and, where a rule could quietly stop applying, against a MUTATION of the
# script that must flip the verdict — and each mutation asserts it was actually
# BUILT (its anchor matched exactly once and the diff is non-empty) before the
# assertion that depends on it, because a mutant that failed to apply produces a
# green that proves nothing.
#
# THE TWO WAYS IT COULD LOSE
#   * silence on a tip that took no verdict  — §1, §5, §7
#   * a scream on a tip that is fine or not yet judged — §2, §3, §4, §6, §8
#
# THE POSITIVE FIXTURE IS RECORDED, NOT INVENTED. §1 replays the run population
# of main sha 0097c711f209293924e9672fa9f4de78afeff015 (2026-09-06): five
# workflows whose runs concluded `cancelled` under the next merge's
# cancel-in-progress, go-tests among them.
#
# FULLY OFFLINE. `gh` is replaced by a stub that fails loudly, so any accidental
# network path in the script under test surfaces as a failing case rather than a
# hidden dependency on GitHub being up.
#
#   bash scripts/main-verdict-presence.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUT="$REPO_ROOT/scripts/main-verdict-presence.sh"
WF="$REPO_ROOT/.github/workflows/main-gate-watch.yml"
MANIFEST="$REPO_ROOT/.github/main-push-workflows.txt"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh: this test is offline and must never call the network (args: $*)" >&2
exit 97
STUB
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"; export PATH

# ── fixture builders ─────────────────────────────────────────────────────────
# mkruns <file> then lines of "<path> <status> <conclusion> <id>" on stdin.
mkruns() {
  local out="$1" path status concl id first=1
  { echo '{"total_count":0,"workflow_runs":['
    while read -r path status concl id; do
      [ -n "${path:-}" ] || continue
      [ "$first" = 1 ] || echo ','
      first=0
      printf '{"path":"%s","status":"%s","conclusion":%s,"id":%s,"name":"%s"}' \
        "$path" "$status" \
        "$([ "$concl" = "null" ] && echo null || printf '"%s"' "$concl")" \
        "$id" "$path"
    done
    echo ']}'
  } > "$out"
}

# mkwf <dir> then lines of "<name> <ALWAYS|CONDITIONAL|NOPUSH>"
mkwf() {
  local dir="$1" name kind
  mkdir -p "$dir"
  while read -r name kind; do
    [ -n "${name:-}" ] || continue
    case "$kind" in
      ALWAYS)      printf 'name: %s\non:\n  push:\n    branches: [main]\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' "$name" > "$dir/$name" ;;
      CONDITIONAL) printf 'name: %s\non:\n  push:\n    branches: [main]\n    paths: ["src/**"]\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' "$name" > "$dir/$name" ;;
      NOPUSH)      printf 'name: %s\non:\n  schedule:\n    - cron: "0 0 * * *"\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' "$name" > "$dir/$name" ;;
    esac
  done
}

# run_sut <workflows-dir> <runs-file> [extra args...] -> sets OUT / RC
run_sut() {
  local wfdir="$1" runs="$2"; shift 2
  OUT="$(bash "$SUT" --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        --runs-file "$runs" --workflows-dir "$wfdir" --no-manifest "$@" 2>&1)"
  RC=$?
}

# run_mutant <script> <workflows-dir> <runs-file> -> sets OUT / RC
run_mutant() {
  local sut="$1" wfdir="$2" runs="$3"; shift 3
  OUT="$(bash "$sut" --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
        --runs-file "$runs" --workflows-dir "$wfdir" --no-manifest "$@" 2>&1)"
  RC=$?
}

# built <mutant> <anchor-regex> <label> — a mutation that did not apply is not a
# catch: the anchor must have matched EXACTLY ONCE in the original and the diff
# must be non-empty.
built() {
  local mutant="$1" anchor="$2" label="$3" hits
  hits="$(grep -cE "$anchor" "$SUT")"
  if [ "$hits" != "1" ]; then
    bad "$label: anchor matched $hits times in the shipped script (want exactly 1) — the mutation is unanchored"
    return 1
  fi
  if diff -q "$SUT" "$mutant" >/dev/null 2>&1; then
    bad "$label: the mutant is byte-identical to the shipped script — this mutation proves nothing"
    return 1
  fi
  return 0
}

echo "main-verdict-presence.test.sh"

# ═══ 1. the recorded specimen SCREAMS ════════════════════════════════════════
section "1. main 0097c711f — five cancelled runs, go-tests among them"
W1="$TMP/w1"; R1="$TMP/r1.json"
mkwf "$W1" <<'EOF'
cloud.yml ALWAYS
elixir.yml ALWAYS
compose-smoke.yml ALWAYS
required-checks-drift.yml ALWAYS
search-template-gates.yml ALWAYS
go-tests.yml CONDITIONAL
go-format.yml CONDITIONAL
shell-harnesses.yml CONDITIONAL
main-gate-watch.yml NOPUSH
EOF
mkruns "$R1" <<'EOF'
.github/workflows/cloud.yml completed success 101
.github/workflows/elixir.yml completed success 102
.github/workflows/compose-smoke.yml completed cancelled 103
.github/workflows/required-checks-drift.yml completed cancelled 104
.github/workflows/search-template-gates.yml completed cancelled 105
.github/workflows/go-tests.yml completed cancelled 106
.github/workflows/go-format.yml completed cancelled 107
EOF
run_sut "$W1" "$R1"
[ "$RC" = "1" ] && ok "exit 1 on the recorded specimen" || bad "expected exit 1, got $RC"
grep -q 'go-tests.yml (cancelled)' <<<"$OUT" && ok "names go-tests.yml as the absent verdict" || bad "go-tests.yml is not named in the scream"
[ "$(grep -c '(cancelled)$' <<<"$OUT")" = "5" ] && ok "all five cancelled workflows are named" || bad "expected 5 cancelled rows, got $(grep -c '(cancelled)$' <<<"$OUT")"
grep -q 'main-gate-watch.yml' <<<"$OUT" && bad "a workflow with no push arm entered the expected set" || ok "a schedule-only workflow is not in the expected set"

# ═══ 2. the negative arm is SILENT ═══════════════════════════════════════════
section "2. every owed workflow published — silence"
R2="$TMP/r2.json"
mkruns "$R2" <<'EOF'
.github/workflows/cloud.yml completed success 201
.github/workflows/elixir.yml completed failure 202
.github/workflows/compose-smoke.yml completed success 203
.github/workflows/required-checks-drift.yml completed success 204
.github/workflows/search-template-gates.yml completed success 205
.github/workflows/go-tests.yml completed success 206
.github/workflows/go-format.yml completed success 207
EOF
run_sut "$W1" "$R2"
[ "$RC" = "0" ] && ok "exit 0 when every owed workflow answered" || bad "expected exit 0, got $RC ($OUT)"
grep -q 'elixir.yml — verdict=failure' <<<"$OUT" && ok "a RED verdict is PRESENT, not screamed (redness is main-gate-watch's subject)" || bad "a failure verdict was not counted as present"

# ═══ 3. in flight is WAITING, not a scream ═══════════════════════════════════
section "3. a run still in flight makes absences premature"
R3="$TMP/r3.json"
mkruns "$R3" <<'EOF'
.github/workflows/cloud.yml completed success 301
.github/workflows/elixir.yml in_progress null 302
EOF
run_sut "$W1" "$R3"
[ "$RC" = "2" ] && ok "exit 2 (WAITING) while a run on the tip is not terminal" || bad "expected exit 2, got $RC"
grep -q "CARRIES NO VERDICT" <<<"$OUT" && bad "screamed while the tip was still being judged" || ok "no scream while the tip is still being judged"

# ═══ 4. an empty payload is WAITING, not a mass scream ═══════════════════════
section "4. zero runs on the tip"
R4="$TMP/r4.json"; : | mkruns "$R4"
run_sut "$W1" "$R4"
[ "$RC" = "2" ] && ok "exit 2 on a tip with no runs at all" || bad "expected exit 2, got $RC"

# ═══ 5. NO_RUN screams for an unfiltered arm, and only for that tier ═════════
section "5. the two tiers"
R5="$TMP/r5.json"
mkruns "$R5" <<'EOF'
.github/workflows/cloud.yml completed success 501
.github/workflows/elixir.yml completed success 502
.github/workflows/compose-smoke.yml completed success 503
.github/workflows/required-checks-drift.yml completed success 504
EOF
run_sut "$W1" "$R5"
[ "$RC" = "1" ] && ok "exit 1 when an unfiltered push arm produced no run" || bad "expected exit 1, got $RC"
grep -q 'search-template-gates.yml (NO_RUN)' <<<"$OUT" && ok "the missing ALWAYS workflow is named NO_RUN" || bad "NO_RUN not reported for search-template-gates.yml"
grep -q 'go-tests.yml (NO_RUN)' <<<"$OUT" && bad "a paths-filtered workflow with no run was screamed — the filter may have correctly declined" || ok "a paths-filtered workflow with no run is NOT screamed"
grep -q 'paths-filtered with no run: 3' <<<"$OUT" && ok "the paths-filtered-with-no-run population is counted and printed" || bad "the NOT_OWED count is not printed ($OUT)"

# ═══ 6. `skipped` is DECLINED, printed, not screamed ═════════════════════════
section "6. a run whose every job's if: was false"
R6="$TMP/r6.json"
mkruns "$R6" <<'EOF'
.github/workflows/cloud.yml completed success 601
.github/workflows/elixir.yml completed success 602
.github/workflows/compose-smoke.yml completed skipped 603
.github/workflows/required-checks-drift.yml completed success 604
.github/workflows/search-template-gates.yml completed success 605
EOF
run_sut "$W1" "$R6"
[ "$RC" = "0" ] && ok "exit 0 — a skipped run is a different defect class with a different owner" || bad "expected exit 0, got $RC"
grep -q 'declined .github/workflows/compose-smoke.yml' <<<"$OUT" && ok "the declined workflow is PRINTED, so it can never be silently zero" || bad "the declined row is not printed"
grep -q 'declined (skipped): 1' <<<"$OUT" && ok "the declined population is counted" || bad "the declined count is not printed"

# ═══ 7. startup_failure is matched as a WHOLE TOKEN ══════════════════════════
section "7. startup_failure — mutation: a substring test files it as a verdict"
R7="$TMP/r7.json"
mkruns "$R7" <<'EOF'
.github/workflows/cloud.yml completed success 701
.github/workflows/elixir.yml completed success 702
.github/workflows/compose-smoke.yml completed startup_failure 703
.github/workflows/required-checks-drift.yml completed success 704
.github/workflows/search-template-gates.yml completed success 705
EOF
run_sut "$W1" "$R7"
[ "$RC" = "1" ] && ok "exit 1 on a startup_failure run (valid YAML, invalid job shape: zero jobs, no verdict)" || bad "expected exit 1, got $RC"
grep -q 'compose-smoke.yml (startup_failure)' <<<"$OUT" && ok "startup_failure is named as an absent verdict" || bad "startup_failure not named"

MUT7="$TMP/mut7.sh"
ANCHOR7='^    success\|failure\|neutral\|timed_out\|action_required\) return 0 ;;$'
sed 's/^    success|failure|neutral|timed_out|action_required) return 0 ;;$/    *success*|*failure*|*neutral*|*timed_out*|*action_required*) return 0 ;;/' "$SUT" > "$MUT7"
if built "$MUT7" '^    success\|failure\|neutral\|timed_out\|action_required\) return 0 ;;$' "§7 substring mutant"; then
  run_mutant "$MUT7" "$W1" "$R7"
  [ "$RC" = "0" ] && ok "MUTATION CONFIRMS: a substring test files startup_failure as a verdict and the read goes silent" \
                  || bad "the substring mutant did not go silent (rc=$RC) — the whole-token rule is not what makes §7 pass"
fi

# ═══ 8. the boolean `on:` key — mutation: drop the fallback, see it go blind ══
section "8. YAML 1.1 resolves a bare on: to a boolean"
MUT8="$TMP/mut8.sh"
sed 's/^    on = doc.get("on", doc.get(True))$/    on = doc.get("on")/' "$SUT" > "$MUT8"
if built "$MUT8" '^    on = doc\.get\("on", doc\.get\(True\)\)$' "§8 boolean-key mutant"; then
  run_mutant "$MUT8" "$W1" "$R1"
  [ "$RC" = "3" ] && ok "MUTATION CONFIRMS: without the boolean-key fallback the derived set is EMPTY and the read refuses (exit 3), it does not report green" \
                  || bad "the blind mutant returned $RC, not 3 — an empty expected set must never be a pass"
fi

# ═══ 9. the ratchet ══════════════════════════════════════════════════════════
section "9. the derived set is compared against the committed transcript"
M9="$TMP/m9.txt"
printf '# header\n.github/workflows/cloud.yml\tALWAYS\n' > "$M9"
OUT="$(bash "$SUT" --sha deadbeef --runs-file "$R2" --workflows-dir "$W1" --manifest "$M9" 2>&1)"; RC=$?
[ "$RC" = "3" ] && ok "exit 3 when a workflow joined or left the main-push set without the transcript learning it" || bad "expected exit 3 on drift, got $RC"
grep -q 'drifted from' <<<"$OUT" && ok "the drift is named" || bad "the drift message is missing"

M9B="$TMP/m9b.txt"
bash "$SUT" --workflows-dir "$W1" --manifest "$M9B" --write-manifest >/dev/null 2>&1
OUT="$(bash "$SUT" --sha deadbeef --runs-file "$R2" --workflows-dir "$W1" --manifest "$M9B" 2>&1)"; RC=$?
[ "$RC" = "0" ] && ok "a regenerated transcript matches the tree and the read proceeds" || bad "expected exit 0 with a fresh transcript, got $RC ($OUT)"

# The shipped transcript must match the shipped tree, or the scheduled arm reds
# on drift the day it lands.
OUT="$(bash "$SUT" --sha deadbeef --runs-file "$R2" --manifest "$MANIFEST" 2>&1)"; RC=$?
[ "$RC" != "3" ] && ok "the COMMITTED transcript matches this repo's own workflow tree" || bad "the committed .github/main-push-workflows.txt is stale: $OUT"

# ═══ 10. there is no hand-written workflow list in the script ════════════════
section "10. the expected set is derived, never typed"
BODY="$(grep -v '^[[:space:]]*#' "$SUT")"
if grep -qE 'go-tests\.yml|compose-smoke\.yml|search-template-gates\.yml' <<<"$BODY"; then
  bad "a watched workflow filename appears in the script's executable body — that is an allowlist, and an allowlist here IS the defect"
else
  ok "no watched workflow filename appears outside the comments"
fi
[ "$(grep -c 'GRACE' <<<"$BODY")" = "0" ] && ok "no age-threshold constant in the executable body" || bad "an age threshold appeared; it was measured and rejected in the sibling watch"

# ═══ 11. the venue publishes no context any merge waits on ══════════════════
section "11. wiring"
if grep -q 'main-verdict-presence.sh' "$WF"; then
  ok "the scheduled venue runs the script"
else
  bad "no venue runs scripts/main-verdict-presence.sh"
fi
if grep -q 'main-verdict-presence.test.sh' "$WF"; then
  ok "the venue runs this harness"
else
  bad "this harness is orphaned — no workflow runs it"
fi
# Every job in main-gate-watch.yml that is not the pull_request harness is fenced
# off pull_request, so none of its names can ever be sampled onto a PR head.
if [ "$(grep -c "if: github.event_name != 'pull_request'" "$WF")" -ge 2 ]; then
  ok "the new job carries the same pull_request fence as its sibling, so its name never renders on a PR head"
else
  bad "a job in $WF is missing the pull_request fence"
fi
if grep -qE '^  push:' "$WF"; then
  bad "a push: trigger came back to $WF — measured as a regression: it fires before GitHub has created any run on the new tip"
else
  ok "no push: trigger (the level schedule is the trigger)"
fi

echo
echo "── $PASS passed, $FAIL failed ──"
[ "$FAIL" = "0" ] || exit 1
exit 0
