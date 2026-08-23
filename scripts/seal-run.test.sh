#!/usr/bin/env bash
# seal-run.test.sh — the mutation proofs for the seal runner's four refusals.
#
# FULLY OFFLINE AND FULLY HERMETIC. Every probe drives scripts/seal-run.sh over
# a `git init`-ed fixture repository built in a temp dir, carrying a stand-in
# predicate that prints a real-shaped `VERDICT-TOKEN:` line and exits on demand.
# Nothing here touches the live ledger, the network, or the repository this file
# lives in. The shallow fixture is made with a `--depth 1` clone of a `file://`
# URL, which is a genuinely shallow repository produced without a remote.
#
# NOTHING HERE ASSERTS "THE SCRIPT RAN". Each of the four refusals is proven by
# MUTATION: the guard's `if` line is neutralised in a copy of the script by its
# `# MUT:` anchor, the same fixture is driven through the mutant, and the refusal
# is watched DISAPPEARING. A guard that cannot be made to stop firing was never
# shown to be load-bearing. The mutation step additionally asserts that the sed
# actually changed a line, so a renamed anchor reds here instead of silently
# turning every mutation proof into a no-op.
#
# THE ASSERTION THIS FILE EXISTS FOR is the last section: a refusal must carry a
# DIFFERENT EXIT CODE from a NO-SEAL and must not print the withheld reading. A
# wrapper that refused with exit 1, or that refused loudly while still leaving
# `a=FAIL b=FAIL` on the terminal, would have changed nothing about wave 28 —
# the false verdict was quotable, and quotable is what has to stop.
#
#   bash scripts/seal-run.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEAL="$ROOT/scripts/seal-run.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok()      { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()     { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

[ -f "$SEAL" ] || { echo "missing $SEAL" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "git is required" >&2; exit 2; }

# ---------------------------------------------------------------------------
# The stand-in predicate. Same stdout contract as the real one: a body, then a
# single `VERDICT-TOKEN: SEAL-PREDICATE …` line carrying head= and (optionally)
# b-unavailable=. The body deliberately contains the string `NO-SEAL a=FAIL`, so
# "the withheld reading was not printed" is an assertion about bytes on the
# terminal rather than a claim about control flow.
#
# `head=` IS `rev-parse --short`, NOT `rev-parse`. The real predicate abbreviates
# (seal-predicate.mjs, `['rev-parse', '--short', 'HEAD']`), and this stand-in used
# to emit the FULL sha — which is the only reason the runner's flat `!=` against
# the 40-char origin sha was green here while refusing exit 5 over every real
# checkout, including one parked exactly at the tip. A stand-in that contradicts
# the emitter it stands in for is a fixture that can only certify itself.
FAKE="$TMP/fake-predicate.mjs"
cat >"$FAKE" <<'EOF'
import { execFileSync } from 'node:child_process';
const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i === -1 ? null : argv[i + 1]; };
const repo = arg('--repo') || process.cwd();
let head = 'NOT-READ';
try { head = execFileSync('git', ['-C', repo, 'rev-parse', '--short', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}
if (process.env.FAKE_HEAD) head = process.env.FAKE_HEAD;
const bu = process.env.FAKE_BUNAVAIL ? ` b-unavailable=${process.env.FAKE_BUNAVAIL}` : '';
console.log('=== SEAL PREDICATE — fixture stand-in ===');
console.log('body line that must never survive a refusal: NO-SEAL a=FAIL b=FAIL');
console.log(`VERDICT-TOKEN: SEAL-PREDICATE ${process.env.FAKE_VERDICT || 'SEAL'} a=PASS b=PASS c=PASS epic=fixture mode=live repo=${repo} head=${head}${bu}`);
process.exit(Number(process.env.FAKE_EXIT || '0'));
EOF

gitq() { git -c user.email=t@example.com -c user.name=t -C "$@"; }

# A full-history fixture checkout parked at its own origin/main.
build_clean() { # <dir>
  local d="$1"
  mkdir -p "$d/cloud/priv/static/__preview__"
  cp "$FAKE" "$d/cloud/priv/static/__preview__/seal-predicate.mjs"
  echo "fixture" >"$d/README"
  git init -q "$d"
  gitq "$d" symbolic-ref HEAD refs/heads/main
  gitq "$d" add -A
  gitq "$d" commit -qm "fixture"
  gitq "$d" update-ref refs/remotes/origin/main HEAD
}

CLEAN="$TMP/clean"; build_clean "$CLEAN"

# HEAD moved off the origin ref — the wave-28 shape.
STALE="$TMP/stale"; cp -R "$CLEAN" "$STALE"
echo "drifted work" >"$STALE/NOTE"
gitq "$STALE" add -A
gitq "$STALE" commit -qm "a commit origin/main does not have"

# The predicate on disk is not the origin ref's copy — the primary checkout's shape.
DRIFT="$TMP/drift"; cp -R "$CLEAN" "$DRIFT"
printf '\n// a pre-wave-9 line origin/main does not carry\n' >>"$DRIFT/cloud/priv/static/__preview__/seal-predicate.mjs"

# The same clean checkout, configured to abbreviate to FOUR characters. `git
# rev-parse --short` honours core.abbrev, so this fixture's head= is `c2de`-shaped
# — and a runner that fixed the 40-vs-abbreviated bug with a bare 7-character
# floor would refuse this correct tree instead. The floor is not the fix; asking
# the repo what IT abbreviates to is.
ABBREV4="$TMP/abbrev4"; cp -R "$CLEAN" "$ABBREV4"
gitq "$ABBREV4" config core.abbrev 4

# A genuinely shallow repository, produced offline from a file:// URL.
SHALLOW="$TMP/shallow"
git clone -q --depth 1 --no-local "file://$CLEAN" "$SHALLOW" 2>/dev/null

run_seal() { # <repo> [args…] -> sets OUT, CODE
  OUT="$(bash "$SEAL" --repo "$@" 2>&1)"
  CODE=$?
}

expect_code() { # <label> <want> <got>
  if [ "$3" = "$2" ]; then ok "$1 -> exit $3"; else bad "$1: expected exit $2, got $3"; fi
}

expect_has() { # <label> <needle>
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1: output lacks '$2'"; printf '%s\n' "$OUT" | sed 's/^/       | /' >&2 ;; esac
}

expect_lacks() { # <label> <needle>
  case "$OUT" in *"$2"*) bad "$1: output contains '$2'"; printf '%s\n' "$OUT" | sed 's/^/       | /' >&2 ;; *) ok "$1" ;; esac
}

# ---------------------------------------------------------------------------
section "the vouched path — the predicate is invoked and its token is parsed"

run_seal "$CLEAN"
expect_code "clean checkout, predicate exit 0" 0 "$CODE"
expect_has  "the predicate was actually executed" "SEAL PREDICATE — fixture stand-in"
expect_has  "the verdict is the predicate's, marked vouched" "seal-run: VOUCHED — SEAL"
expect_has  "the token's fields are echoed back" "token head="
CLEAN_HEAD="$(gitq "$CLEAN" rev-parse HEAD)"
CLEAN_SHORT="$(gitq "$CLEAN" rev-parse --short HEAD)"
expect_has  "the head= it vouches for is the fixture's tip, abbreviated as the predicate abbreviates it" "token head=$CLEAN_SHORT"
[ "${#CLEAN_SHORT}" -lt 40 ] \
  && ok "the fixture's head= really is ABBREVIATED (${#CLEAN_SHORT} chars) — the shape the runner must accept" \
  || bad "the fixture emits a 40-char head=, so it no longer models the real predicate's --short contract"

OUT="$(FAKE_EXIT=1 FAKE_VERDICT=NO-SEAL bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "clean checkout, predicate exit 1" 1 "$CODE"
expect_has  "a real NO SEAL is passed through untouched" "seal-run: VOUCHED — NO SEAL"

OUT="$(FAKE_EXIT=2 bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "clean checkout, predicate exit 2 (infra fault)" 2 "$CODE"

# ---------------------------------------------------------------------------
section "refusal 3 — a shallow --repo"

if [ ! -d "$SHALLOW/.git" ]; then
  bad "the shallow fixture could not be built (git clone --depth 1 file:// failed)"
else
  [ "$(gitq "$SHALLOW" rev-parse --is-shallow-repository)" = "true" ] \
    && ok "the shallow fixture really is shallow" \
    || bad "the shallow fixture is not shallow — the probe below would be vacuous"
  run_seal "$SHALLOW"
  expect_code "shallow checkout" 3 "$CODE"
  expect_has  "it names the condition" "is a SHALLOW repository"
  expect_has  "it names the remedy"    "fetch --unshallow"
  expect_lacks "the predicate was not executed at all" "SEAL PREDICATE — fixture stand-in"
fi

# ---------------------------------------------------------------------------
section "refusal 4 — the predicate on disk is not origin/main's copy"

run_seal "$DRIFT"
expect_code "drifted predicate" 4 "$CODE"
expect_has  "it names the condition" "is NOT origin/main's copy"
expect_has  "it names the remedy"    "checkout origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs"
expect_lacks "the wrong program was never run" "SEAL PREDICATE — fixture stand-in"

# ---------------------------------------------------------------------------
section "refusal 5 — HEAD is not origin/main's tip (the wave-28 tree)"

run_seal "$STALE"
expect_code "stale worktree" 5 "$CODE"
expect_has  "it names the condition" "not origin/main's tip"
expect_has  "it names wave 28's symptom" "wave 28's false a=FAIL b=FAIL"
expect_has  "it names the remedy" "checkout origin/main"

section "refusal 5 — read off the token's own head= field"

OUT="$(FAKE_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "token head= disagrees with origin/main's tip" 5 "$CODE"
expect_has  "the refusal quotes the token field" "the token says head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
expect_lacks "the reading is withheld, not printed with a warning above it" "NO-SEAL a=FAIL b=FAIL"

# ---------------------------------------------------------------------------
# A TRUTHFUL ABBREVIATION IS NOT A WRONG TREE. The token's head= is abbreviated,
# the wrapper's $ORIGIN_SHA is 40 characters, and the two are never string-equal:
# comparing them flatly refused every correct checkout in the field while every
# probe here stayed green, because the stand-in used to emit the full sha. These
# six cases pin both halves — what must now be ACCEPTED, and what must still be
# REFUSED, so the repair cannot slide into "any head= will do".
section "refusal 5 — a truthful abbreviation is the tip; a lie is still a lie"

run_seal "$CLEAN"
expect_code "the predicate's own --short head= vouches" 0 "$CODE"

OUT="$(FAKE_HEAD="${CLEAN_HEAD:0:9}" bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "an explicit 9-character truthful abbreviation vouches" 0 "$CODE"

run_seal "$ABBREV4"
ABBREV4_SHORT="$(gitq "$ABBREV4" rev-parse --short HEAD)"
[ "${#ABBREV4_SHORT}" -eq 4 ] \
  && ok "the core.abbrev=4 fixture really abbreviates to 4 ($ABBREV4_SHORT) — otherwise the probe below is vacuous" \
  || bad "the core.abbrev=4 fixture emits ${#ABBREV4_SHORT} chars — a 7-char floor would not be tested"
expect_code "a core.abbrev=4 checkout vouches (a 7-character floor alone would refuse it)" 0 "$CODE"
expect_has  "…and the 4-character head= is the one it vouched for" "token head=$ABBREV4_SHORT"

OUT="$(FAKE_HEAD="${CLEAN_HEAD:0:1}" bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "a 1-character head= is still refused — one hex digit names 1/16th of git" 5 "$CODE"

LIE9="$(printf '%s' "${CLEAN_HEAD:0:9}" | tr '0-9a-f' 'b-f0-9a')"
[ "$LIE9" != "${CLEAN_HEAD:0:9}" ] \
  && ok "the truthful-length lie really differs from the tip ($LIE9 vs ${CLEAN_HEAD:0:9})" \
  || bad "the truthful-length lie collided with the tip — the probe below is vacuous"
OUT="$(FAKE_HEAD="$LIE9" bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "a 9-character LIE is refused — length is not the test, prefix is" 5 "$CODE"
expect_has  "the refusal quotes the lying field" "the token says head=$LIE9"

# ---------------------------------------------------------------------------
section "refusal 6 — a non-empty b-unavailable="

OUT="$(FAKE_BUNAVAIL=6/6 bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "b-unavailable=6/6" 6 "$CODE"
expect_has  "it quotes the field" "b-unavailable=6/6"
expect_has  "it says this is not a finding" "not a finding about the epic"
expect_lacks "the reading is withheld" "NO-SEAL a=FAIL b=FAIL"
# REFUSAL 6 IS NOT SHADOWED. Refusals are collected and REFUSAL_CODE keeps the
# FIRST, so while refusal 5 fired on every abbreviated head= this exact tree
# exited 5 — refusal 6's sentence printed, its EXIT CODE never did, and a caller
# branching on 6 had never once seen it. The code above is the assertion; the
# line below is why it is the assertion.
expect_lacks "…and no head= refusal is riding along to steal the exit code" "which is not origin/main's tip"

OUT="$(FAKE_BUNAVAIL=0/6 bash "$SEAL" --repo "$CLEAN" 2>&1)"; CODE=$?
expect_code "b-unavailable=0/6 is a successful read, not a refusal" 0 "$CODE"

OUT="$(FAKE_BUNAVAIL=6/6 bash "$SEAL" --repo "$CLEAN" --show-withheld 2>&1)"; CODE=$?
expect_code "--show-withheld still refuses" 6 "$CODE"
expect_has  "--show-withheld does print the void letters on request" "NO-SEAL a=FAIL b=FAIL"

# ---------------------------------------------------------------------------
section "unusable inputs refuse with 7 — never with a verdict code"

OUT="$(bash "$SEAL" --repo "$TMP/does-not-exist" 2>&1)"; CODE=$?
expect_code "a --repo that does not exist" 7 "$CODE"
NOTGIT="$TMP/notgit"; mkdir -p "$NOTGIT"
OUT="$(bash "$SEAL" --repo "$NOTGIT" 2>&1)"; CODE=$?
expect_code "a --repo that is not a work tree" 7 "$CODE"
NOREF="$TMP/noref"; build_clean "$NOREF"; gitq "$NOREF" update-ref -d refs/remotes/origin/main
OUT="$(bash "$SEAL" --repo "$NOREF" 2>&1)"; CODE=$?
expect_code "a --repo with no origin/main to compare against" 7 "$CODE"
expect_has  "it names the remedy" "fetch origin main"

# ---------------------------------------------------------------------------
# --predicate WAS A DECOY (dr-w34-bl-seal-run-predicate-flag-is-a-decoy): the
# usage block advertised it, but refusal 4 compared the executed file against
# the HARDCODED origin-ref blob of the canonical path, so any --predicate that
# was not a byte-identical copy was a guaranteed pre-run exit 4 whose remedy
# named a file the caller never passed. The flag is deleted. These probes pin
# the deletion three ways: the refusal is DEDICATED (its sentence names the
# removal — the generic unknown-argument arm cannot produce it, so deleting the
# dedicated arm reds HERE, attributably), it is NOT the misleading blob-drift
# refusal, and the usage block no longer advertises the flag. A revert that
# makes --predicate parse again turns this run into an exit-0 vouch (the file
# passed is byte-identical to the canonical copy) and reds the exit-7 probe.
section "--predicate is no such flag — the decoy escape hatch is deleted"

OTHERPRED="$TMP/other-predicate.mjs"
printf '// not the canonical predicate\n' >"$OTHERPRED"
cp "$FAKE" "$TMP/identical-predicate.mjs"

OUT="$(bash "$SEAL" --repo "$CLEAN" --predicate "$OTHERPRED" 2>&1)"; CODE=$?
expect_code  "--predicate <some other file> refuses at the parser" 7 "$CODE"
expect_has   "the refusal is the DEDICATED one, naming the removal" "--predicate is no such flag (removed)"
expect_has   "…and it names the ONLY path the runner executes" "cloud/priv/static/__preview__/seal-predicate.mjs"
expect_lacks "…it is NOT the blob-drift refusal (which named the wrong file)" "blob"
expect_lacks "…and no predicate was executed at all" "SEAL PREDICATE — fixture stand-in"

OUT="$(bash "$SEAL" --repo "$CLEAN" --predicate "$TMP/identical-predicate.mjs" 2>&1)"; CODE=$?
expect_code  "even a byte-identical --predicate is refused — there is no flag to satisfy" 7 "$CODE"
expect_has   "…with the same dedicated sentence" "--predicate is no such flag (removed)"

grep -q -- '--predicate <path>' "$SEAL" \
  && bad "the usage block still advertises --predicate <path> — the decoy survives in the help text" \
  || ok "the usage block no longer advertises --predicate"

# ---------------------------------------------------------------------------
section "a refusal is never a verdict — the exit-code table"

table_code() { OUT="$(env "$2" bash "$SEAL" --repo "$1" 2>&1)"; echo $?; }
C_SEAL=$(table_code "$CLEAN"   FAKE_EXIT=0)
C_NOSEAL=$(table_code "$CLEAN" FAKE_EXIT=1)
C_SHALLOW=$(table_code "$SHALLOW" FAKE_EXIT=0)
C_DRIFT=$(table_code "$DRIFT"  FAKE_EXIT=0)
C_STALE=$(table_code "$STALE"  FAKE_EXIT=0)
C_BUNAV=$(table_code "$CLEAN"  FAKE_BUNAVAIL=6/6)
echo "     SEAL=$C_SEAL  NO-SEAL=$C_NOSEAL  shallow=$C_SHALLOW  drift=$C_DRIFT  stale-head=$C_STALE  b-unavailable=$C_BUNAV"
UNIQ="$(printf '%s\n' "$C_SEAL" "$C_NOSEAL" "$C_SHALLOW" "$C_DRIFT" "$C_STALE" "$C_BUNAV" | sort -u | wc -l | tr -d ' ')"
[ "$UNIQ" = "6" ] && ok "all six outcomes carry distinct exit codes" || bad "outcomes collide: only $UNIQ distinct exit codes"
for c in "$C_SHALLOW" "$C_DRIFT" "$C_STALE" "$C_BUNAV"; do
  [ "$c" != "$C_NOSEAL" ] || bad "a refusal shares the NO-SEAL exit code ($c)"
done
ok "no refusal shares the NO-SEAL exit code"

for repo_arg in "$SHALLOW" "$DRIFT" "$STALE"; do
  OUT="$(bash "$SEAL" --repo "$repo_arg" 2>&1)"
  expect_has   "refusal over $(basename "$repo_arg") says no verdict was taken" "no seal verdict was taken"
  expect_lacks "refusal over $(basename "$repo_arg") reads as no finding" "NO-SEAL a=FAIL"
done

# ---------------------------------------------------------------------------
# THE MUTATION PROOFS. Each guard is neutralised by its `# MUT:` anchor and the
# refusal is watched disappearing. A guard whose absence changes nothing was
# decorative.
section "mutation — each refusal is proven able to stop firing"

MUTANT=""
make_mutant() { # <anchor> -> sets MUTANT to a copy of seal-run.sh with that guard disabled
  local anchor="$1"
  MUTANT="$TMP/mutant-$anchor.sh"
  sed "s|^if .*# MUT:$anchor\$|if false; then # MUT:$anchor|" "$SEAL" >"$MUTANT"
  if ! grep -q "^if false; then # MUT:$anchor\$" "$MUTANT"; then
    bad "mutation anchor MUT:$anchor did not apply — every proof under it would be vacuous"
    return 1
  fi
  return 0
}

mutate_run() { # <anchor> <repo> [env…] -> sets OUT, CODE
  make_mutant "$1" || { OUT=""; CODE=-1; return 1; }
  local repo="$2"; shift 2
  OUT="$(env "$@" bash "$MUTANT" --repo "$repo" 2>&1)"; CODE=$?
}

mutate_run G-SHALLOW "$SHALLOW" FAKE_EXIT=0
[ "$CODE" != "3" ] && ok "MUT:G-SHALLOW disabled -> the shallow refusal is gone (exit $CODE)" \
                   || bad "MUT:G-SHALLOW disabled but the shallow refusal still fired — the proof is vacuous"

mutate_run G-DRIFT "$DRIFT" FAKE_EXIT=0
[ "$CODE" != "4" ] && ok "MUT:G-DRIFT disabled -> the drift refusal is gone (exit $CODE)" \
                   || bad "MUT:G-DRIFT disabled but the drift refusal still fired — the proof is vacuous"

# The pre-run head leg and the token head leg are separate guards over the same
# fact, so each is disarmed alone. Disabling the pre-run leg must let the run
# HAPPEN and hand the catch to the token leg; disabling the token leg over a tree
# git itself cannot fault must let a lying head= through.
mutate_run G-HEAD "$STALE" FAKE_EXIT=0
expect_lacks "MUT:G-HEAD disabled -> the pre-run refusal is gone" "the predicate was NOT executed"
expect_has  "MUT:G-HEAD disabled -> the predicate ran and its reading was withheld instead" "the reading is WITHHELD"
expect_has  "MUT:G-HEAD disabled -> the token leg catches it instead" "the token says head="

mutate_run G-TOKENHEAD "$CLEAN" FAKE_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
[ "$CODE" != "5" ] && ok "MUT:G-TOKENHEAD disabled -> a lying head= is no longer refused (exit $CODE)" \
                   || bad "MUT:G-TOKENHEAD disabled but the token refusal still fired — the proof is vacuous"

mutate_run G-BUNAVAIL "$CLEAN" FAKE_BUNAVAIL=6/6
[ "$CODE" != "6" ] && ok "MUT:G-BUNAVAIL disabled -> the b-unavailable refusal is gone (exit $CODE)" \
                   || bad "MUT:G-BUNAVAIL disabled but the refusal still fired — the proof is vacuous"

# ---------------------------------------------------------------------------
section "the fence — the runner never writes to the predicate"

BEFORE="$(gitq "$CLEAN" hash-object cloud/priv/static/__preview__/seal-predicate.mjs)"
bash "$SEAL" --repo "$CLEAN" >/dev/null 2>&1
AFTER="$(gitq "$CLEAN" hash-object cloud/priv/static/__preview__/seal-predicate.mjs)"
[ "$BEFORE" = "$AFTER" ] && ok "the predicate is byte-identical after a run" \
                         || bad "the runner modified the predicate"
STATE_BEFORE="$(gitq "$CLEAN" rev-parse HEAD; gitq "$CLEAN" status --porcelain; gitq "$CLEAN" for-each-ref)"
bash "$SEAL" --repo "$CLEAN" >/dev/null 2>&1
FAKE_BUNAVAIL=6/6 bash "$SEAL" --repo "$CLEAN" >/dev/null 2>&1
STATE_AFTER="$(gitq "$CLEAN" rev-parse HEAD; gitq "$CLEAN" status --porcelain; gitq "$CLEAN" for-each-ref)"
[ "$STATE_BEFORE" = "$STATE_AFTER" ] && ok "HEAD, refs and the working tree are untouched by a run" \
                                     || bad "the runner changed git state under --repo"

# ---------------------------------------------------------------------------
# THE PARSER IS BOUND TO THE REAL EMITTER, NOT ONLY TO THE STAND-IN.
#
# Every probe above drives a stand-in predicate, so all of them would still pass
# if the REAL seal-predicate.mjs renamed `head=` or `b-unavailable=`: `tok()`
# matches on field NAME, an absent field reads empty, and both post-run refusals
# are guarded by `[ -n … ]` — so a rename makes the runner silently stop checking
# and VOUCH for a tree it did not verify. That is a fail-OPEN, and it was the
# sharpest blind spot in what this slice shipped.
#
# It cannot be closed inside the fenced file (D402), so it is closed from here:
# assert that origin/main's own predicate still EMITS both field names in a
# `VERDICT-TOKEN:` template literal. A rename now reds this file — where the
# runner's silence would have been the only other signal.
section "the runner's field names are the predicate's field names"

PRED_REAL="$ROOT/cloud/priv/static/__preview__/seal-predicate.mjs"
if [ ! -f "$PRED_REAL" ]; then
  bad "the real predicate is not at $PRED_REAL — the runner's parser is bound to nothing"
else
  EMITTERS="$(grep -c 'VERDICT-TOKEN: SEAL-PREDICATE' "$PRED_REAL" || true)"
  [ "${EMITTERS:-0}" -ge 1 ] \
    && ok "the real predicate emits a VERDICT-TOKEN line ($EMITTERS producer(s))" \
    || bad "the real predicate emits no VERDICT-TOKEN line — the runner would refuse 7 on every read"

  # Both names are asserted ON A TOKEN-EMITTING LINE, not merely somewhere in the
  # file: the prose above them explains the fields at length, so a bare file-wide
  # grep would survive the exact rename this probe exists to catch.
  # The token lines are materialised, never piped — honest-gates D37. `grep FILE
  # | grep -q …` is a pipeline, not a file match: `grep -q` exits at its first
  # match, the producing grep takes SIGPIPE, and `set -o pipefail` reports its
  # 141 over the match. For the two arms below that would only cost a spurious
  # red, but for the DISARM it is silent — the disarm reports "does NOT emit"
  # for a name the predicate does emit, and the two oks stop being load-bearing.
  pred_token_lines="$(grep 'VERDICT-TOKEN: SEAL-PREDICATE' "$PRED_REAL")"

  grep -q 'head=' <<<"$pred_token_lines" \
    && ok "…and it still emits head= on that line (seal-run.sh's tok head)" \
    || bad "the predicate no longer emits head= — seal-run.sh's stale-tree refusal has silently stopped checking"

  grep -q 'b-unavailable=' <<<"$pred_token_lines" \
    && ok "…and it still emits b-unavailable= on that line (seal-run.sh's tok b-unavailable)" \
    || bad "the predicate no longer emits b-unavailable= — seal-run.sh's history refusal has silently stopped checking"

  # Able to fail: the same two greps against a name the predicate does not use
  # must NOT match, so the two oks above are matching the field and not the prose.
  grep -q 'b-unreadable=' <<<"$pred_token_lines" \
    && bad "the disarm matched a field name the predicate does not emit — these greps are not load-bearing" \
    || ok "disarm: a field name the predicate does NOT emit fails the same grep"
fi

# ---------------------------------------------------------------------------
# ONE REAL END-TO-END EXECUTION — the greps above are about SOURCE TEXT, and the
# defect this section was written to catch was about SHAPE. `head=` never went
# missing; it went ABBREVIATED, and every grep here matched happily while the
# runner refused exit 5 over every live tree it was ever pointed at. So the real
# predicate is executed THROUGH the runner, once, over a purpose-built fixture
# checkout that carries it at its committed path — no network (the ladder path
# reads committed files and git only), no ledger, ~0.4s.
#
# The fixture has no history, so the register's fixes are unreachable and the
# predicate honestly reports `b-unavailable=M/M`: exit 6. THAT is the assertion —
# a runner that mis-compares head= exits 5 here instead, which is exactly what it
# did before this slice, and it is the only probe in this file that would have
# noticed.
section "the real predicate, executed through the runner, over a real checkout"

E2E="$TMP/e2e-real"
if [ ! -f "$PRED_REAL" ] || [ ! -f "$ROOT/.github/workflows/cloud.yml" ]; then
  bad "the e2e fixture cannot be built (needs the real predicate and .github/workflows/cloud.yml under $ROOT)"
else
  mkdir -p "$E2E/cloud/priv/static/__preview__" "$E2E/.github/workflows"
  cp "$PRED_REAL" "$E2E/cloud/priv/static/__preview__/seal-predicate.mjs"
  cp "$ROOT/.github/workflows/cloud.yml" "$E2E/.github/workflows/cloud.yml"
  [ -f "$ROOT/.github/required-checks.json" ] && cp "$ROOT/.github/required-checks.json" "$E2E/.github/required-checks.json"
  git init -q "$E2E"
  gitq "$E2E" symbolic-ref HEAD refs/heads/main
  gitq "$E2E" add -A
  gitq "$E2E" commit -qm "e2e fixture carrying the real predicate"
  gitq "$E2E" update-ref refs/remotes/origin/main HEAD

  E2E_SHORT="$(gitq "$E2E" rev-parse --short HEAD)"
  OUT="$(bash "$SEAL" --repo "$E2E" --epic deploy-reliability-epic --show-withheld -- --ladder-only 2>&1)"; CODE=$?

  expect_has "the REAL predicate ran through the runner and emitted its own token" "VERDICT-TOKEN: SEAL-PREDICATE LADDER-ONLY"
  expect_has "the runner parsed the real token's head= and quotes it back" "head=$E2E_SHORT"
  [ "${#E2E_SHORT}" -lt 40 ] \
    && ok "the real emitter's head= is ABBREVIATED (${#E2E_SHORT} chars) — the contract the stand-in now mirrors" \
    || bad "the real emitter's head= is 40 chars — the stand-in's --short contract has drifted from it"
  expect_code "a truthful abbreviated head= is NOT refused; the historyless fixture refuses 6, not 5" 6 "$CODE"
  expect_has "…and the refusal it does carry is the honest one" "the predicate could not read the history"
  expect_lacks "…with no head= refusal shadowing it" "which is not origin/main's tip"
fi

# ---------------------------------------------------------------------------
echo
echo "seal-run.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
