#!/usr/bin/env bash
# deploy-reliability-exit-run.test.sh — the mutation proofs for the exit runner.
#
# FULLY OFFLINE AND FULLY HERMETIC. Every probe drives
# scripts/deploy-reliability-exit-run.sh over `git init`-ed fixture repositories
# built in a temp dir, against a STUB producer that stamps whatever commit it is
# told to and prints a real-shaped census envelope. Nothing here touches the
# control plane, the network, the ledger, or the repository this file lives in.
# The shallow fixture is a `--depth 1` clone of a `file://` URL — a genuinely
# shallow repository produced without a remote.
#
# NOTHING HERE ASSERTS "THE SCRIPT RAN". Each refusal is proven by MUTATION: the
# guard's `if` line is neutralised in a copy of the runner by its `# MUT:` anchor,
# the same fixture is driven through the mutant, and the refusal is watched
# DISAPPEARING. A guard that cannot be made to stop firing was never shown to be
# load-bearing. The mutation step asserts the sed actually changed a line, so a
# renamed anchor reds here instead of turning every proof into a no-op.
#
# THE ASSERTIONS THIS FILE EXISTS FOR:
#   1. A REFUSAL WITHHOLDS THE NUMBER. Not "prints a warning above it" — the
#      digits must be ABSENT from the bytes on the terminal. A refusal that still
#      leaves `never_covered 5` in the scrollback is quotable, and quotable is
#      exactly what has to stop.
#   2. rc=128 IS NOT rc=1. "The commit is not in this object database" must never
#      render as "the commit is off the history". One is "I could not look".
#   3. THE REMEDY IS NEVER `make cli-install` ALONE. Rebuilding from a diverged
#      checkout mints the same diverged binary — the loop `make doctor` prints.
#
#   bash scripts/deploy-reliability-exit-run.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/scripts/deploy-reliability-exit-run.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok()      { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()     { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

[ -f "$RUN" ] || { echo "missing $RUN" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

CENSUS_SRC="internal/cli/cloud_deploy_census_cmd.go"

# ---------------------------------------------------------------------------
# THE STUB PRODUCER. Same two contracts as the real `bp`: `version -o json`
# carrying a `commit` key, and `cloud deployments --from X --to Y` printing a
# census envelope on stdout. Knobs are environment variables so one stub serves
# every probe.
#
# The envelope's shape is copied from a REAL reading taken on 2026-08-09 (the one
# quoted in scripts/deploy-reliability-exit-2026-08-10.md), trimmed to the fields
# the runner reads. It deliberately carries `never_covered 5` and `live_rate 33.3`
# so "the reading was withheld" is an assertion about BYTES, not about control
# flow.
STUB="$TMP/bp-stub"
cat >"$STUB" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "version" ]; then
  if [ -n "${STUB_NO_COMMIT-}" ]; then
    echo '{"build_date":"2026-08-10T00:00:00Z","cli_version":"stub"}'
  else
    printf '{"build_date":"2026-08-10T00:00:00Z","cli_version":"stub","commit":"%s"}\n' "${STUB_COMMIT}"
  fi
  exit 0
fi
# cloud deployments --from X --to Y
FROM=""; TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --to)   TO="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${STUB_ROUTE_ERROR-}" ]; then
  echo '{"error":{"code":"auth","message":"not logged in"},"ok":false}'
  exit "${STUB_EXIT:-1}"
fi
if [ -n "${STUB_GARBAGE-}" ]; then
  echo 'panic: runtime error'
  exit "${STUB_EXIT:-2}"
fi
[ -n "${STUB_ECHO_FROM-}" ] && FROM="$STUB_ECHO_FROM"
[ -n "${STUB_ECHO_TO-}" ] && TO="$STUB_ECHO_TO"
NEVER_PROD="${STUB_NEVER_PROD:-3}"
NEVER_PREVIEW="${STUB_NEVER_PREVIEW:-2}"
NEVER=$((NEVER_PROD + NEVER_PREVIEW))
UNREADABLE="${STUB_UNREADABLE:-0}"
if [ -n "${STUB_LIVE_REFUSED-}" ]; then
  LIVE_RATE='{"refused":true,"reason":"a fixture refusal of live_rate","pct":null,"numerator":11066,"sample":33229}'
else
  LIVE_RATE='{"refused":false,"reason":null,"pct":33.3,"numerator":11066,"sample":33229}'
fi
cat <<JSON
{"scope":{"registered_sites":13},
 "window":{"from":"$FROM","to":"$TO"},
 "volume":33229,"live":11066,"failed":18647,"in_flight":0,"cancelled":0,"total_sites":12,
 "live_rate":$LIVE_RATE,
 "failure_rate":{"refused":true,"reason":"the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z","pct":null,"numerator":18647,"sample":33229},
 "completeness":{"audited":33236,"accounted":33236,"unaccounted":0,"balanced":true},
 "coverage_cohorts":{"as_of":"$TO","maturity_seconds":86400,"cohorts":[
   {"cohort":"deferred","never_covered":0,"never_covered_by_environment":[],"too_young":12,"pending":12,"unreadable":0},
   {"cohort":"failed","never_covered":$NEVER,"never_covered_by_environment":[{"environment":"production","never_covered":$NEVER_PROD},{"environment":"preview","never_covered":$NEVER_PREVIEW}],"too_young":0,"pending":5,"unreadable":$UNREADABLE}
 ]}}
JSON
exit "${STUB_EXIT:-0}"
STUBEOF
chmod +x "$STUB"

gitq() { git -c user.email=t@example.com -c user.name=t -C "$@"; }

build_repo() { # <dir> — two commits on main, origin/main at the tip, plus a diverged commit
  local d="$1"
  mkdir -p "$d/$(dirname "$CENSUS_SRC")"
  echo "// fixture census source" >"$d/$CENSUS_SRC"
  echo "fixture" >"$d/README"
  git init -q "$d"
  gitq "$d" symbolic-ref HEAD refs/heads/main
  gitq "$d" add -A
  gitq "$d" commit -qm "first"
  echo "more" >>"$d/README"
  gitq "$d" add -A
  gitq "$d" commit -qm "tip"
  gitq "$d" update-ref refs/remotes/origin/main HEAD
  # a commit that EXISTS in this object database and is NOT on origin/main
  gitq "$d" checkout -q -b sidetrack
  echo "diverged" >>"$d/README"
  gitq "$d" add -A
  gitq "$d" commit -qm "diverged"
  gitq "$d" checkout -q main
}

REPO="$TMP/repo"; build_repo "$REPO"
TIP="$(gitq "$REPO" rev-parse --short HEAD)"
BEHIND="$(gitq "$REPO" rev-parse --short HEAD~1)"
DIVERGED="$(gitq "$REPO" rev-parse --short sidetrack)"
UNKNOWN_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

FROM_ARG="2026-07-01T00:00:00Z"
TO_ARG="2026-08-09T00:00:00Z"

run_exit() { # <env assignments…> -- <extra runner args…> -> sets OUT, CODE
  local envs=() args=()
  while [ $# -gt 0 ]; do
    [ "$1" = "--" ] && { shift; args=("$@"); break; }
    envs+=("$1"); shift
  done
  OUT="$(env "${envs[@]}" bash "$RUN" --bp "$STUB" --repo "$REPO" --from "$FROM_ARG" --to "$TO_ARG" "${args[@]+"${args[@]}"}" 2>&1)"
  CODE=$?
}

expect_code() { # <label> <want> <got>
  if [ "$3" = "$2" ]; then ok "$1 -> exit $3"; else bad "$1: expected exit $2, got $3"; printf '%s\n' "$OUT" | sed 's/^/       | /' >&2; fi
}
expect_has() { # <label> <needle>
  case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1: output lacks '$2'"; printf '%s\n' "$OUT" | sed 's/^/       | /' >&2 ;; esac
}
expect_lacks() { # <label> <needle>
  case "$OUT" in *"$2"*) bad "$1: output contains '$2'"; printf '%s\n' "$OUT" | sed 's/^/       | /' >&2 ;; *) ok "$1" ;; esac
}

# ---------------------------------------------------------------------------
section "the vouched path — a producer ON the shipped history yields a reading"

run_exit "STUB_COMMIT=$TIP" --
expect_code "producer commit IS origin/main's tip" 0 "$CODE"
expect_has  "the reading is printed" "DEPLOY-RELIABILITY EXIT READING"
expect_has  "live_rate is published" "live_rate     33.3%"
expect_has  "never_covered is published" "never_covered 5"
expect_has  "the environment split is published" "production=3"
expect_has  "…both arms of it" "preview=2"
expect_has  "the window is printed with the number" "[$FROM_ARG .. $TO_ARG]"
expect_has  "the producer and its ancestry verdict are printed" "ancestry=current"
expect_has  "the cost band and the client cap are stated" "client cap 90s"
expect_has  "the honest limit is stated — it is a stuck-site detector" "a STUCK-SITE detector"
expect_has  "…and that the default width reads 0" "default width (--days 7) this same number reads 0"
expect_has  "…and that preview is uncoverable by construction" "preview arm is uncoverable by construction"

run_exit "STUB_COMMIT=$BEHIND" --
expect_code "a producer BEHIND the tip is still quotable" 0 "$CODE"
expect_has  "…and says so" "ancestry=behind"

# NO FLEET FAILURE PERCENTAGE, EVER. The envelope carries failed=18647 and a
# denominator; printing 56.1% would be arithmetically easy and epistemically
# false, because every window this reading can be taken over straddles the
# deferred-settle boundary.
section "the reading publishes no fleet failure percentage"

run_exit "STUB_COMMIT=$TIP" --
expect_has "failure_rate is printed as a REFUSAL with its reason" "failure_rate  REFUSED"
expect_has "…naming the boundary" "deferred settle status boundary"
if grep -Eq 'failure_rate[^R]*[0-9]+(\.[0-9]+)?%' <<<"$OUT"; then
  bad "a failure percentage was printed beside failure_rate"
else
  ok "no failure percentage appears anywhere beside failure_rate"
fi
# Able to fail: the same grep DOES match a line that carries one.
if printf 'failure_rate  56.1%%\n' | grep -Eq 'failure_rate[^R]*[0-9]+(\.[0-9]+)?%'; then
  ok "disarm: the percentage grep matches a line that really carries one"
else
  bad "the percentage grep cannot match a percentage — the probe above is vacuous"
fi

# ---------------------------------------------------------------------------
section "refusal 5 — the producer is OFF the shipped history (rc=1)"

run_exit "STUB_COMMIT=$DIVERGED" --
expect_code "a commit that exists here and is not on origin/main" 5 "$CODE"
expect_has  "it names the condition and the rc it read" "--is-ancestor rc=1"
expect_lacks "THE NUMBER IS WITHHELD — never_covered is absent" "never_covered 5"
expect_lacks "…and live_rate is absent" "33.3%"
expect_lacks "the census was never called" "DEPLOY-RELIABILITY EXIT READING"
expect_has  "it says no reading was taken" "no exit reading was taken"
expect_has  "it says nothing about deploy reliability" "None of it is a statement about deploy reliability"

# THE REMEDY IS TWO STEPS, IN ORDER. `make cli-install` alone rebuilds from the
# same diverged checkout and hands back the same refusal — the loop `make doctor`
# currently prints.
REMEDY_LINE="$(printf '%s\n' "$OUT" | grep 'do this:' | grep 'cli-install' | head -1)"
case "$REMEDY_LINE" in
  *"pull --rebase"*"cli-install"*) ok "the remedy says pull/rebase THEN cli-install, in that order" ;;
  *) bad "the remedy does not put pull --rebase before make cli-install: '$REMEDY_LINE'" ;;
esac

# ---------------------------------------------------------------------------
# rc=128 IS A DIFFERENT ANSWER FROM rc=1, AND IT GETS A DIFFERENT EXIT CODE.
# Both were measured on the owner's host: rc=1 for the PATH binary's real commit,
# rc=128 for an invented sha. A runner that collapses them turns "I could not
# look" into a confident finding.
section "refusal 6 — ancestry could not be evaluated (rc=128)"

run_exit "STUB_COMMIT=$UNKNOWN_SHA" --
expect_code "a commit that is not in this object database" 6 "$CODE"
expect_has  "it names the rc it actually read" "--is-ancestor rc=128"
expect_has  "it says this is 'I could not look'" "This is 'I could not look'"
expect_lacks "it does NOT claim the commit is off the history" "is NOT on $ROOT"
expect_lacks "…and does not borrow refusal 5's sentence" "was never shipped"
expect_lacks "the number is withheld here too" "never_covered 5"

# ---------------------------------------------------------------------------
section "refusal 7 — an unstamped producer has no provenance at all"

run_exit "STUB_COMMIT=$TIP" "STUB_NO_COMMIT=1" --
expect_code "bp version omits the commit key (a plain go build)" 7 "$CODE"
expect_has  "it says the provenance is unknowable" "carries NO commit stamp"
expect_lacks "the number is withheld" "never_covered 5"

section "refusal 7 — --days is refused, because its right edge is now"

run_exit "STUB_COMMIT=$TIP" -- --days 7
expect_code "--days" 7 "$CODE"
expect_has  "it explains why a --days window is not re-runnable" "right edge is \`now\`"
expect_has  "it quotes the reading's own instability across widths" "reads 0 at the built-in 7-day default"
expect_has  "it names the replacement" "--from $FROM_ARG --to $TO_ARG"

section "refusal 7 — an inverted or half-open window"

OUT="$(STUB_COMMIT=$TIP bash "$RUN" --bp "$STUB" --repo "$REPO" --from "$TO_ARG" --to "$FROM_ARG" 2>&1)"; CODE=$?
expect_code "from after to" 7 "$CODE"
expect_has  "it names the condition" "not from < to"

OUT="$(STUB_COMMIT=$TIP bash "$RUN" --bp "$TMP/no-such-binary" --repo "$REPO" 2>&1)"; CODE=$?
expect_code "a --bp that is not executable" 7 "$CODE"
OUT="$(STUB_COMMIT=$TIP bash "$RUN" --bp "$STUB" --repo "$TMP/not-a-repo" 2>&1)"; CODE=$?
expect_code "a --repo that is not a work tree" 7 "$CODE"

# ---------------------------------------------------------------------------
section "refusal 4 — the census source in this checkout is not origin/main's"

DRIFT_REPO="$TMP/drift"; cp -R "$REPO" "$DRIFT_REPO"
printf '\n// a line origin/main does not carry\n' >>"$DRIFT_REPO/$CENSUS_SRC"
OUT="$(STUB_COMMIT=$TIP bash "$RUN" --bp "$STUB" --repo "$DRIFT_REPO" --from "$FROM_ARG" --to "$TO_ARG" 2>&1)"; CODE=$?
expect_code "a drifted census source" 4 "$CODE"
expect_has  "it names the file" "$CENSUS_SRC"
expect_has  "it says why the rebuild remedy would not help" "would mint a different program under the same name"
expect_lacks "the number is withheld" "never_covered 5"

# ---------------------------------------------------------------------------
section "refusal 3 — a shallow checkout cannot decide ancestry at all"

SHALLOW="$TMP/shallow"
git clone -q --depth 1 --no-local "file://$REPO" "$SHALLOW" 2>/dev/null
if [ ! -d "$SHALLOW/.git" ]; then
  bad "the shallow fixture could not be built (git clone --depth 1 file:// failed)"
else
  [ "$(gitq "$SHALLOW" rev-parse --is-shallow-repository)" = "true" ] \
    && ok "the shallow fixture really is shallow" \
    || bad "the shallow fixture is not shallow — the probe below would be vacuous"
  OUT="$(STUB_COMMIT=$TIP bash "$RUN" --bp "$STUB" --repo "$SHALLOW" --from "$FROM_ARG" --to "$TO_ARG" 2>&1)"; CODE=$?
  expect_code "a shallow --repo" 3 "$CODE"
  expect_has  "it names the condition" "is a SHALLOW repository"
  expect_has  "it names the remedy" "fetch --unshallow"
  expect_lacks "the number is withheld" "never_covered 5"
fi

# ---------------------------------------------------------------------------
# POST-RUN REFUSALS. The census HAS run and the digits exist in memory; the whole
# question is whether they reach the terminal.
section "post-run refusal 5 — the route echoed back a different window"

run_exit "STUB_COMMIT=$TIP" "STUB_ECHO_TO=2026-08-08T00:00:00Z" --
expect_code "the echoed window disagrees with the requested one" 5 "$CODE"
expect_has  "it quotes both windows" "which is not the window that was asked for"
expect_lacks "THE READING IS WITHHELD, not printed with a warning above it" "never_covered 5"
expect_lacks "…and no live_rate survives either" "33.3%"
expect_has  "it says the reading was withheld" "the reading is WITHHELD"

run_exit "STUB_COMMIT=$TIP" "STUB_ECHO_TO=2026-08-08T00:00:00Z" -- --show-withheld
expect_code "--show-withheld still refuses" 5 "$CODE"
expect_has  "--show-withheld does print the void digits on request" "never_covered 5"

section "post-run refusal 6 — rows the census could not read"

run_exit "STUB_COMMIT=$TIP" "STUB_UNREADABLE=4" --
expect_code "unreadable rows in a coverage cohort" 6 "$CODE"
expect_has  "it quotes the count" "reports 4 row(s) whose box content marker could not be read"
expect_has  "it says this is not a finding" "not a finding about deploy reliability"
expect_lacks "the reading is withheld" "never_covered 5"

# ---------------------------------------------------------------------------
# A NEGATIVE IS NOT A REFUSAL. When the ROUTE refuses live_rate, that is a fact
# about the fleet's data and it is PRINTED — with its own exit code, distinct
# from every refusal above.
section "exit 1 — the route refuses the number itself (a finding, not a refusal)"

run_exit "STUB_COMMIT=$TIP" "STUB_LIVE_REFUSED=1" --
expect_code "live_rate.refused" 1 "$CODE"
expect_has  "the reading is still printed — this is a finding" "DEPLOY-RELIABILITY EXIT READING"
expect_has  "live_rate is shown as refused with its reason" "live_rate     REFUSED"
expect_has  "never_covered still stands beside it" "never_covered 5"
expect_has  "it says the finding is about the data" "about the DATA, not about this checkout"

section "exit 2 — infra fault is not a refusal and not a finding"

run_exit "STUB_COMMIT=$TIP" "STUB_ROUTE_ERROR=1" "STUB_EXIT=1" --
expect_code "the route named its own error" 2 "$CODE"
expect_has  "it says no reading was taken" "INFRA FAULT (exit 2)"
expect_has  "it names the timeout reading" "a timeout at ~90s is a SLOW PLANE, not a broken gauge"
expect_has  "it says there is no correlator" "no request id"
expect_lacks "no number is printed" "never_covered 5"

run_exit "STUB_COMMIT=$TIP" "STUB_GARBAGE=1" "STUB_EXIT=2" --
expect_code "the producer printed something that is not a census envelope" 2 "$CODE"

# ---------------------------------------------------------------------------
section "a refusal is never a reading — the exit-code table"

table_code() { OUT="$(env "$@" bash "$RUN" --bp "$STUB" --repo "$REPO" --from "$FROM_ARG" --to "$TO_ARG" 2>&1)"; echo $?; }
C_READ=$(table_code "STUB_COMMIT=$TIP")
C_NEG=$(table_code "STUB_COMMIT=$TIP" "STUB_LIVE_REFUSED=1")
C_INFRA=$(table_code "STUB_COMMIT=$TIP" "STUB_ROUTE_ERROR=1")
C_DIVERGED=$(table_code "STUB_COMMIT=$DIVERGED")
C_UNKNOWN=$(table_code "STUB_COMMIT=$UNKNOWN_SHA")
C_NOSTAMP=$(table_code "STUB_COMMIT=$TIP" "STUB_NO_COMMIT=1")
C_UNREAD=$(table_code "STUB_COMMIT=$TIP" "STUB_UNREADABLE=4")
echo "     reading=$C_READ  negative=$C_NEG  infra=$C_INFRA  off-history=$C_DIVERGED  unknown-ancestry=$C_UNKNOWN  unstamped=$C_NOSTAMP  unreadable=$C_UNREAD"
[ "$C_DIVERGED" != "$C_UNKNOWN" ] \
  && ok "rc=1 and rc=128 carry DIFFERENT exit codes ($C_DIVERGED vs $C_UNKNOWN)" \
  || bad "rc=1 and rc=128 collapse to the same exit code ($C_DIVERGED) — 'I could not look' reads as a finding"
for c in "$C_DIVERGED" "$C_UNKNOWN" "$C_NOSTAMP" "$C_UNREAD"; do
  [ "$c" != "$C_READ" ] && [ "$c" != "$C_NEG" ] || bad "a refusal shares a reading's exit code ($c)"
done
ok "no refusal shares an exit code with a reading or a negative"

# ---------------------------------------------------------------------------
section "mutation — each guard is proven able to stop firing"

MUTANT=""
make_mutant() { # <anchor>
  local anchor="$1"
  MUTANT="$TMP/mutant-$anchor.sh"
  sed "s|^if .*# MUT:$anchor\$|if false; then # MUT:$anchor|" "$RUN" >"$MUTANT"
  if ! grep -q "^if false; then # MUT:$anchor\$" "$MUTANT"; then
    bad "mutation anchor MUT:$anchor did not apply — every proof under it would be vacuous"
    return 1
  fi
  return 0
}

mutate_run() { # <anchor> <repo> <env…> -- <args…>
  make_mutant "$1" || { OUT=""; CODE=-1; return 1; }
  local repo="$2"; shift 2
  local envs=() args=()
  while [ $# -gt 0 ]; do
    [ "$1" = "--" ] && { shift; args=("$@"); break; }
    envs+=("$1"); shift
  done
  OUT="$(env "${envs[@]}" bash "$MUTANT" --bp "$STUB" --repo "$repo" --from "$FROM_ARG" --to "$TO_ARG" "${args[@]+"${args[@]}"}" 2>&1)"; CODE=$?
}

mutate_run G-DIVERGED "$REPO" "STUB_COMMIT=$DIVERGED" --
[ "$CODE" != "5" ] && ok "MUT:G-DIVERGED disabled -> the off-history refusal is gone (exit $CODE)" \
                   || bad "MUT:G-DIVERGED disabled but the refusal still fired — the proof is vacuous"

mutate_run G-UNKNOWNANC "$REPO" "STUB_COMMIT=$UNKNOWN_SHA" --
[ "$CODE" != "6" ] && ok "MUT:G-UNKNOWNANC disabled -> the unknown-ancestry refusal is gone (exit $CODE)" \
                   || bad "MUT:G-UNKNOWNANC disabled but the refusal still fired — the proof is vacuous"

mutate_run G-NOSTAMP "$REPO" "STUB_COMMIT=$TIP" "STUB_NO_COMMIT=1" --
[ "$CODE" != "7" ] && ok "MUT:G-NOSTAMP disabled -> the unstamped-producer refusal is gone (exit $CODE)" \
                   || bad "MUT:G-NOSTAMP disabled but the refusal still fired — the proof is vacuous"

mutate_run G-DAYS "$REPO" "STUB_COMMIT=$TIP" -- --days 7
[ "$CODE" != "7" ] && ok "MUT:G-DAYS disabled -> --days is no longer refused (exit $CODE)" \
                   || bad "MUT:G-DAYS disabled but --days was still refused — the proof is vacuous"

mutate_run G-DRIFT "$DRIFT_REPO" "STUB_COMMIT=$TIP" --
[ "$CODE" != "4" ] && ok "MUT:G-DRIFT disabled -> the source-drift refusal is gone (exit $CODE)" \
                   || bad "MUT:G-DRIFT disabled but the refusal still fired — the proof is vacuous"

if [ -d "$SHALLOW/.git" ]; then
  mutate_run G-SHALLOW "$SHALLOW" "STUB_COMMIT=$TIP" --
  [ "$CODE" != "3" ] && ok "MUT:G-SHALLOW disabled -> the shallow refusal is gone (exit $CODE)" \
                     || bad "MUT:G-SHALLOW disabled but the refusal still fired — the proof is vacuous"
fi

# The two post-run guards are the ones that decide whether digits reach the
# terminal, so disarming them must let the WITHHELD number through — that is the
# proof that withholding was doing the work, not luck.
mutate_run G-WINDOW "$REPO" "STUB_COMMIT=$TIP" "STUB_ECHO_TO=2026-08-08T00:00:00Z" --
[ "$CODE" != "5" ] && ok "MUT:G-WINDOW disabled -> the window refusal is gone (exit $CODE)" \
                   || bad "MUT:G-WINDOW disabled but the refusal still fired — the proof is vacuous"
expect_has "MUT:G-WINDOW disabled -> the withheld number now DOES reach the terminal" "never_covered 5"

mutate_run G-UNREADABLE "$REPO" "STUB_COMMIT=$TIP" "STUB_UNREADABLE=4" --
[ "$CODE" != "6" ] && ok "MUT:G-UNREADABLE disabled -> the unreadable refusal is gone (exit $CODE)" \
                   || bad "MUT:G-UNREADABLE disabled but the refusal still fired — the proof is vacuous"
expect_has "MUT:G-UNREADABLE disabled -> the withheld number now DOES reach the terminal" "never_covered 5"

# ---------------------------------------------------------------------------
section "read-only — a run changes nothing under --repo"

STATE_BEFORE="$(gitq "$REPO" rev-parse HEAD; gitq "$REPO" status --porcelain; gitq "$REPO" for-each-ref)"
STUB_COMMIT=$TIP bash "$RUN" --bp "$STUB" --repo "$REPO" --from "$FROM_ARG" --to "$TO_ARG" >/dev/null 2>&1
STUB_COMMIT=$DIVERGED bash "$RUN" --bp "$STUB" --repo "$REPO" --from "$FROM_ARG" --to "$TO_ARG" >/dev/null 2>&1
STATE_AFTER="$(gitq "$REPO" rev-parse HEAD; gitq "$REPO" status --porcelain; gitq "$REPO" for-each-ref)"
[ "$STATE_BEFORE" = "$STATE_AFTER" ] && ok "HEAD, refs and the working tree are untouched by a run" \
                                     || bad "the runner changed git state under --repo"

# ---------------------------------------------------------------------------
# BOUND TO THE REAL SURFACES, NOT ONLY TO THE STUB. Every probe above drives a
# stand-in, so all of them would stay green if the real CLI renamed the flags or
# the client changed its cap — and the artefact's quoted 90s would silently
# become fiction. These probes bind the claims to the source that makes them true.
section "the runner's claims are bound to the real CLI and client"

CLIENT="$ROOT/internal/cloudclient/client.go"
if [ ! -f "$CLIENT" ]; then
  bad "the cloud client is not at $CLIENT — the 90s cap this runner prints is bound to nothing"
else
  grep -q 'FleetDeployCensusTimeout = 90 \* time.Second' "$CLIENT" \
    && ok "the client still caps the census at 90s, absolutely (the number the runner prints)" \
    || bad "FleetDeployCensusTimeout is no longer 90s — the runner's cost sentence and the artefact are stale"
  grep -q 'FleetDeployCensusTimeout = 900 \* time.Second' "$CLIENT" \
    && bad "the cap grep matched a value the client does not carry — it is not load-bearing" \
    || ok "disarm: a cap value the client does NOT carry fails the same grep"
fi

CMD="$ROOT/$CENSUS_SRC"
if [ ! -f "$CMD" ]; then
  bad "the census command is not at $CMD — the runner's flags are bound to nothing"
else
  grep -q '"from", "to", "days", "sites"' "$CMD" \
    && ok "the census command still parses from/to/days/sites (the flags the runner sends and refuses)" \
    || bad "the census command's flag set moved — the runner may be sending flags it would now reject"
fi

# THE TAXONOMY IS SEAL-RUN'S, REUSED — AND seal-run.sh IS NOT TOUCHED BY THIS
# SLICE. Both halves are asserted: the shared code→family lines, and byte
# identity against origin/main where that ref is resolvable.
SEAL="$ROOT/scripts/seal-run.sh"
if [ ! -f "$SEAL" ]; then
  bad "scripts/seal-run.sh is missing — the taxonomy this runner reuses has no owner"
else
  TAX_OK=1
  LINE="7  REFUSED — the inputs are unusable"
  grep -q "$LINE" "$SEAL" || { bad "seal-run.sh no longer documents '$LINE' — the reused taxonomy has drifted"; TAX_OK=0; }
  grep -q "$LINE" "$RUN"  || { bad "the exit runner no longer documents '$LINE'"; TAX_OK=0; }
  # THE SHALLOW FAMILY DIVERGED BY NUMBER, NOT BY MEANING (task-cfa85992568a4bdc).
  # seal-run.sh had to give up 3: `cloud/priv/static/__preview__/seal-predicate.mjs`
  # now exits 3 for a `Refusal` (it measured NOTHING), seal-run.sh forwards the
  # predicate's own codes untouched, and two different refusals must not share one
  # code — so seal-run's shallow refusal moved to 8. THIS runner drives no predicate,
  # has no fourth code to forward, and keeps 3. The family name is still asserted in
  # BOTH files, each at the number it actually documents, so renaming or deleting the
  # family still reds here while the deliberate renumber does not.
  grep -q "8  REFUSED — shallow repository" "$SEAL" \
    || { bad "seal-run.sh no longer documents '8  REFUSED — shallow repository' — the reused taxonomy has drifted"; TAX_OK=0; }
  grep -q "3  REFUSED — shallow repository" "$RUN" \
    || { bad "the exit runner no longer documents '3  REFUSED — shallow repository'"; TAX_OK=0; }
  [ "$TAX_OK" = "1" ] && ok "both scripts document the same refusal families (shallow at 8 here / 3 there, unusable input at 7 in both)"

  ORIGIN_SEAL="$(git -C "$ROOT" rev-parse --verify --quiet origin/main:scripts/seal-run.sh 2>/dev/null || true)"
  if [ -z "$ORIGIN_SEAL" ]; then
    ok "origin/main is not resolvable here — the seal-run byte-identity probe is skipped, not faked"
  else
    HAVE_SEAL="$(git -C "$ROOT" hash-object "$SEAL")"
    [ "$ORIGIN_SEAL" = "$HAVE_SEAL" ] \
      && ok "scripts/seal-run.sh is byte-identical to origin/main — this slice is a sibling, not a re-point" \
      || bad "scripts/seal-run.sh differs from origin/main — this slice was supposed to leave it alone"
  fi
fi

# ---------------------------------------------------------------------------
# THE ARTEFACT'S OWN INVARIANTS. The verdict doc is the thing being shipped; its
# two structural promises are checkable here rather than by eye.
section "the verdict artefact carries what it promises"

DOC="$ROOT/scripts/deploy-reliability-exit-2026-08-10.md"
if [ ! -f "$DOC" ]; then
  bad "the verdict artefact is missing at $DOC"
else
  head -1 "$DOC" | grep -q 'canonical-for: deploy-reliability-exit-reading' \
    && ok "the artefact carries canonical-for: deploy-reliability-exit-reading" \
    || bad "the artefact's canonical-for slug is not deploy-reliability-exit-reading"
  # NO RELATIVE .md LINKS: docs-anchors-check section 3c does not reach scripts/,
  # so a broken one here would never be caught. Documents are named in prose.
  if grep -Eq '\]\([^)]*\.md[^)]*\)' "$DOC"; then
    bad "the artefact carries a relative .md link — nothing gates link resolution under scripts/"
  else
    ok "the artefact carries no relative .md links (nothing would gate them here)"
  fi
  grep -q 'UNVERIFIED' "$DOC" \
    && ok "the artefact carries its explicit UNVERIFIED section" \
    || bad "the artefact has no UNVERIFIED section — everything in it claims to be re-derived"
  # check-doc-budgets.sh is a hardcoded heredoc plus docs/cards/*.md — it does not
  # scan scripts/ at all, so a `budget:` header here is decorative without a line.
  grep -q 'scripts/deploy-reliability-exit-2026-08-10.md' "$ROOT/scripts/check-doc-budgets.sh" \
    && ok "the artefact has its own line in check-doc-budgets.sh (which does not scan scripts/ by pattern)" \
    || bad "the artefact is not in check-doc-budgets.sh's CAPS heredoc — its budget header would be decorative"
fi

# ---------------------------------------------------------------------------
echo
echo "deploy-reliability-exit-run.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
