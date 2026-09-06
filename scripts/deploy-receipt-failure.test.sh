#!/usr/bin/env bash
#
# deploy-receipt-failure.test.sh — every deploy receipt must descend from a
# measurement, or refuse.
#
# THE DEFECT IT GUARDS (PDS wave 48/49, task
# pds-bl-w48-deploy-make-and-rebuild-receipts). Three receipts on the legacy
# single-box deploy lane asserted states nobody had observed:
#
#   FM-A  `make deploy` printed ">> Pulled. .githooks/post-merge cleaned
#         _build/prod, recompiled, and restarted." unconditionally and exited 0
#         — over a rebuild that FAILED. `git pull` exits 0 whatever the hook
#         does, so the recipe had no channel to learn otherwise and did not
#         look for one.
#   FM-B  scripts/deploy-rebuild.sh printed "Done. Service restarted." on the
#         strength of `sudo systemctl restart` returning 0. `grep -c curl` over
#         that whole file returned 0: no liveness evidence existed anywhere in
#         the one engine shared by `make rebuild`, the post-merge hook and the
#         self-update endpoint.
#   FM-C  the hook NO-OPS entirely on a laptop (".githooks/post-merge:
#         Not the barkpark server") and `make deploy` printed BYTE-IDENTICAL
#         `>>` lines to FM-A. A diff of the two runs' receipts was EMPTY — the
#         receipt could not distinguish "the rebuild failed" from "nothing was
#         even attempted". Not merely unmeasured: information-free across its
#         whole failure space.
#
# POLARITY. Every assertion below names a REFUSAL or a MEASURED green, never
# the fraud. So this harness is RED against unrepaired sources and GREEN
# against the repair — run it both ways:
#
#     bash scripts/deploy-receipt-failure.test.sh              # this tree
#     bash scripts/deploy-receipt-failure.test.sh /path/to/tree
#
# The tree argument only has to contain Makefile, .githooks/post-merge and
# scripts/deploy-rebuild.sh, so the fail-before run is three `git show
# origin/main:<file>` into a temp dir.
#
# HERMETIC, and it proves it. PATH is exactly two directories: a stub bin
# (git, systemctl, sudo, mix, flock, curl, make, sleep) and a symlink ALLOWLIST
# of real coreutils. `go` is in NEITHER — which is the point: deploy-rebuild.sh
# prepends /usr/local/go/bin to PATH, so on any runner with Go installed
# (every ubuntu-latest) the unrepaired script reaches a REAL toolchain and a
# REAL `make wasm` around the stubs. The repair makes that prefix overridable
# (BP_DEPLOY_PATH_PREFIX, unset in prod); the `make` stub is a TRIPWIRE writing
# to DANGER_LOG, and every arm asserts that log is empty. Arms run under
# `env -i` so no ambient environment leaks in, with GOPROXY=off and
# GOTOOLCHAIN=local as a second fence in case a real go is reached anyway.
# `sleep` is stubbed to return instantly — the harness measures receipts, not
# wall clock. Nothing here touches a real service, build or network. ~2s.
set -uo pipefail

SRC="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$(cd "$SRC" && pwd)"
for f in Makefile .githooks/post-merge scripts/deploy-rebuild.sh; do
  [ -f "$SRC/$f" ] || { echo "FATAL: $SRC/$f is missing — cannot test a tree without the subjects."; exit 2; }
done

REAL_MAKE="$(command -v make || true)"
[ -n "$REAL_MAKE" ] || { echo "FATAL: no make on PATH."; exit 2; }

PASS=0; FAIL=0; FAILED_NAMES=""
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  - $1"; echo "FAIL: $1"; }
# assert_has NAME FILE NEEDLE   — the receipt SAYS the honest thing
assert_has()  { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (missing: $3)"; fi; }
assert_lacks(){ if grep -qF -- "$3" "$2"; then bad "$1 (present but must not be: $3)"; else ok "$1"; fi; }
assert_rc()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (rc=$2, want $3)"; fi; }
assert_rc_ne(){ if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (rc=$2, must not be $3)"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deploy-receipt.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# ── The stub PATH ────────────────────────────────────────────────────────────
BIN="$ROOT/bin"; ALLOW="$ROOT/allow"
mkdir -p "$BIN" "$ALLOW"
for c in bash sh env cat cp mkdir mv rm rmdir ls grep sed chmod dirname basename \
         true false printf date find head tail tr wc diff mktemp awk expr uname; do
  p="$(command -v "$c" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$ALLOW/$c"
done
if [ -x "$ALLOW/go" ] || [ -x "$BIN/go" ]; then
  echo "FATAL: a real go leaked into the harness PATH — the run would not be hermetic."; exit 2
fi

# The stub bodies below are single-quoted ON PURPOSE: $VAR inside them must be
# expanded when the STUB runs, not when this harness writes it.
# shellcheck disable=SC2016
mk() { printf '%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }

mk sleep '#!/bin/sh
exit 0'

# git: `pull` IS running the hook then exiting 0 — that is literally what git
# does, the fast-forward lands even when the hook dies. Everything else the two
# subjects ask git is answered from the fixture.
mk git '#!/bin/sh
case "$1" in
  pull)
    if [ "${STUB_GIT_RUN_HOOK:-yes}" = "yes" ]; then
      bash .githooks/post-merge || true
    fi
    exit 0 ;;
  rev-parse)
    case "$2" in
      --git-dir) echo "${STUB_GIT_DIR:-.git}" ;;
      *) echo 0000000000000000000000000000000000000000 ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac'

# systemctl: two independent knobs — does the barkpark unit EXIST (the hook'\''s
# server-only guard) and is it ACTIVE (deploy-rebuild'\''s restart guard).
mk systemctl '#!/bin/sh
case "$1" in
  list-unit-files)
    [ "${STUB_UNIT_EXISTS:-yes}" = "yes" ] && echo "barkpark.service enabled enabled"
    exit 0 ;;
  is-active)
    [ "${STUB_UNIT_ACTIVE:-yes}" = "yes" ] && exit 0
    exit 3 ;;
  *) exit 0 ;;
esac'

mk sudo '#!/bin/sh
exec "$@"'

# mix: MIX_BUILD_ROOT=_build_next `compile` materialises the aside build so the
# swap has something to move. STUB_MIX_FAIL picks which verb refuses.
mk mix '#!/bin/sh
verb="$1"
case "${STUB_MIX_FAIL:-}" in
  compile)      [ "$verb" = "compile" ] && { echo "== stub mix: compile FAILED"; exit 1; } ;;
  ecto.migrate) [ "$verb" = "ecto.migrate" ] && { echo "== stub mix: migrate FAILED"; exit 1; } ;;
esac
if [ "$verb" = "compile" ]; then
  mkdir -p "${MIX_BUILD_ROOT:-_build}/prod"
  echo NEW > "${MIX_BUILD_ROOT:-_build}/prod/marker"
fi
echo "== stub mix: $* OK"
exit 0'

# flock: deploy-rebuild.sh uses the util-linux `flock 8` FD form, so a
# `shift 2; exec "$@"` stub would die rc 127. Plain success is correct here.
mk flock '#!/bin/sh
exit 0'

# curl: consumes STUB_CURL_CODES one entry per call, from a counter file, so a
# run can hand deploy-rebuild'\''s probe one answer and make'\''s own probe another.
# "dead" = rc 7 with empty stdout (connection refused), which is what the
# subjects see when the API is down.
mk curl '#!/bin/sh
n=0
[ -f "$STUB_CURL_N" ] && n="$(cat "$STUB_CURL_N")"
i=0; pick=""
for c in ${STUB_CURL_CODES:-dead}; do
  if [ "$i" -eq "$n" ]; then pick="$c"; fi
  i=$((i+1))
done
[ -n "$pick" ] || pick="$(printf "%s" "${STUB_CURL_CODES:-dead}" | awk "{print \$NF}")"
echo $((n+1)) > "$STUB_CURL_N"
echo "curl $*" >> "$STUB_CURL_LOG"
if [ "$pick" = "dead" ]; then exit 7; fi
printf "%s" "$pick"
exit 0'

# make: a TRIPWIRE, never a build. Any nested `make` (deploy-rebuild.sh'\''s
# `make wasm`) is an escape from the stub PATH into a real Go toolchain; it is
# recorded and every arm asserts the log is empty.
mk make '#!/bin/sh
echo "NESTED MAKE ESCAPED THE STUB PATH: make $*" >> "$DANGER_LOG"
exit 0'

# ── One arm = one fresh tree + one run ───────────────────────────────────────
ARM_N=0
new_tree() {
  ARM_N=$((ARM_N+1))
  T="$ROOT/arm$ARM_N"
  mkdir -p "$T/scripts" "$T/.githooks" "$T/api/_build/prod" "$T/.git"
  cp "$SRC/Makefile" "$T/Makefile"
  cp "$SRC/.githooks/post-merge" "$T/.githooks/post-merge"
  cp "$SRC/scripts/deploy-rebuild.sh" "$T/scripts/deploy-rebuild.sh"
  chmod +x "$T/.githooks/post-merge" "$T/scripts/deploy-rebuild.sh"
  echo OLD > "$T/api/_build/prod/marker"
  DANGER="$T/danger.log"; : > "$DANGER"
  CURLLOG="$T/curl.log"; : > "$CURLLOG"
  CURLN="$T/curl.n"; echo 0 > "$CURLN"
  OUT="$T/out.txt"
}

# run_in TREE ENV... -- COMMAND...   (env -i, stub PATH only)
run_arm() {
  ( cd "$T" && env -i \
      PATH="$BIN:$ALLOW" \
      HOME="$T" \
      TMPDIR="$T" \
      LC_ALL=C \
      GOPROXY=off \
      GOFLAGS=-mod=mod \
      GOTOOLCHAIN=local \
      DANGER_LOG="$DANGER" \
      STUB_CURL_LOG="$CURLLOG" \
      STUB_CURL_N="$CURLN" \
      STUB_GIT_DIR="$T/.git" \
      BP_DEPLOY_PATH_PREFIX="$BIN" \
      BP_HEALTH_ATTEMPTS=2 \
      BP_HEALTH_SLEEP=0 \
      BP_DEPLOY_POLL_ATTEMPTS=2 \
      BP_DEPLOY_POLL_SLEEP=0 \
      "$@" \
    > "$OUT" 2>&1 )
  echo $?
}
make_deploy() { run_arm "$@" "$REAL_MAKE" -f "$T/Makefile" -C "$T" deploy; }
rebuild()     { run_arm "$@" bash "$T/scripts/deploy-rebuild.sh"; }

receipt() { grep '^>>' "$1" > "$2" 2>/dev/null || true; }

echo "── deploy receipts: every claim descends from a measurement, or refuses ──"
echo "   subject tree: $SRC"
echo

# ─────────────────────────────────────────────────────────────────────────────
# FM-A — the rebuild genuinely fails.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(make_deploy STUB_MIX_FAIL=compile STUB_CURL_CODES="dead dead")
FMA_RECEIPT="$T/receipt.txt"; receipt "$OUT" "$FMA_RECEIPT"
echo "--- FM-A (rebuild fails) rc=$rc ---"; cat "$FMA_RECEIPT"
assert_rc_ne "FM-A: make deploy does NOT exit 0 over a failed rebuild" "$rc" 0
assert_lacks "FM-A: the receipt does NOT assert the three unobserved facts" "$OUT" "cleaned _build/prod, recompiled"
assert_has   "FM-A: the receipt NAMES the failed rebuild"                   "$OUT" "REBUILD FAILED"
assert_has   "FM-A: it says the OLD build is still serving"                 "$OUT" "OLD build is still serving"
assert_lacks "FM-A: the laundering string is gone"                          "$OUT" "Warming up"
assert_lacks "FM-A: it never claims the API is live"                        "$OUT" "API is live"
if [ ! -s "$DANGER" ]; then ok "FM-A: no nested make/go escaped the stub PATH"; else bad "FM-A: escape recorded: $(cat "$DANGER")"; fi

# ─────────────────────────────────────────────────────────────────────────────
# FM-B — systemd accepts the restart; the app never answers.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(rebuild STUB_CURL_CODES="dead dead")
echo "--- FM-B (restart accepted, app dead) rc=$rc ---"; tail -3 "$OUT"
assert_rc    "FM-B: deploy-rebuild.sh exits with the typed restart-unverified code 15" "$rc" 15
assert_lacks "FM-B: it does NOT claim 'Done. Service restarted.'"  "$OUT" "Done. Service restarted."
assert_has   "FM-B: it NAMES the unverified restart"               "$OUT" "RESTART UNVERIFIED"
assert_has   "FM-B: it says the new build IS installed"            "$OUT" "new build IS installed"
assert_has   "FM-B: it reached the restart at all (fixture control)" "$OUT" "Restarting service..."
if [ -s "$CURLLOG" ]; then ok "FM-B: the probe was actually TAKEN (curl called $(wc -l < "$CURLLOG" | tr -d ' ')x)"; else bad "FM-B: no curl call recorded — the probe never ran, the arm is vacuous"; fi
if [ ! -s "$DANGER" ]; then ok "FM-B: no nested make/go escaped the stub PATH"; else bad "FM-B: escape recorded: $(cat "$DANGER")"; fi
assert_has   "FM-B: the pdrender wasm build was SKIPPED (go absent), not run" "$OUT" "go not found"

# ─────────────────────────────────────────────────────────────────────────────
# FM-B2 — the same state carried through `make deploy`: unverified, NOT failed.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(make_deploy STUB_CURL_CODES="dead dead dead dead")
echo "--- FM-B2 (unverified, through make deploy) rc=$rc ---"; grep '^>>' "$OUT" || true
assert_rc_ne "FM-B2: make deploy does NOT exit 0 over an unverified deploy" "$rc" 0
assert_has   "FM-B2: the receipt says the deploy is NOT VERIFIED"           "$OUT" "NOT VERIFIED"
assert_lacks "FM-B2: it does NOT mis-report an installed build as a build failure" "$OUT" "REBUILD FAILED"
assert_lacks "FM-B2: the laundering string is gone"                        "$OUT" "Warming up"

# ─────────────────────────────────────────────────────────────────────────────
# FM-C — the hook no-ops on a laptop. Its receipt must be DISTINGUISHABLE.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(make_deploy STUB_UNIT_EXISTS=no STUB_CURL_CODES="dead dead")
FMC_RECEIPT="$T/receipt.txt"; receipt "$OUT" "$FMC_RECEIPT"
echo "--- FM-C (laptop no-op) rc=$rc ---"; cat "$FMC_RECEIPT"
assert_has "FM-C: the hook actually hit its server-only guard (fixture control)" "$OUT" "Not the barkpark server"
assert_rc_ne "FM-C: make deploy does NOT exit 0 having deployed nothing"         "$rc" 0
assert_has   "FM-C: the receipt says NO rebuild was attempted"                   "$OUT" "NO rebuild was attempted"
assert_has   "FM-C: it names WHY it was skipped"                                 "$OUT" "not-the-barkpark-server"
assert_lacks "FM-C: it does NOT assert the three unobserved facts"               "$OUT" "cleaned _build/prod, recompiled"
if diff -q "$FMA_RECEIPT" "$FMC_RECEIPT" >/dev/null 2>&1; then
  bad "FM-C: the >> receipt is BYTE-IDENTICAL to the failed-rebuild receipt — information-free"
else
  ok "FM-C: the >> receipt DIFFERS from the failed-rebuild receipt"
fi

# ─────────────────────────────────────────────────────────────────────────────
# FM-C2 — the OTHER no-op path: a blue/green slot box.
# ─────────────────────────────────────────────────────────────────────────────
new_tree; mkdir -p "$T/.slots"
rc=$(make_deploy STUB_CURL_CODES="dead dead")
FMC2_RECEIPT="$T/receipt.txt"; receipt "$OUT" "$FMC2_RECEIPT"
echo "--- FM-C2 (slot box) rc=$rc ---"; cat "$FMC2_RECEIPT"
assert_rc_ne "FM-C2: make deploy does NOT exit 0 on a slot box"  "$rc" 0
assert_has   "FM-C2: it names the slot-layout skip"              "$OUT" "blue-green-slot-layout"
if diff -q "$FMC_RECEIPT" "$FMC2_RECEIPT" >/dev/null 2>&1; then
  bad "FM-C2: the slot receipt is byte-identical to the laptop receipt"
else
  ok "FM-C2: the slot receipt DIFFERS from the laptop no-op receipt"
fi

# ─────────────────────────────────────────────────────────────────────────────
# FM-C3 — the hook never ran at all (hooks not installed). Silence is not green.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(make_deploy STUB_GIT_RUN_HOOK=no STUB_CURL_CODES="dead dead")
echo "--- FM-C3 (hook never ran) rc=$rc ---"; grep '^>>' "$OUT" || true
assert_rc_ne "FM-C3: make deploy does NOT exit 0 when the hook never ran" "$rc" 0
assert_has   "FM-C3: the receipt says NO outcome was recorded"            "$OUT" "recorded NO outcome"
assert_lacks "FM-C3: it does NOT assert the three unobserved facts"       "$OUT" "cleaned _build/prod, recompiled"

# ─────────────────────────────────────────────────────────────────────────────
# FM-C4 — a STALE outcome file from a previous deploy cannot green this one.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
echo rebuilt > "$T/.git/barkpark-deploy-outcome"
rc=$(make_deploy STUB_GIT_RUN_HOOK=no STUB_CURL_CODES="200 200")
echo "--- FM-C4 (stale 'rebuilt' record, hook never ran) rc=$rc ---"; grep '^>>' "$OUT" || true
assert_rc_ne "FM-C4: a stale outcome file cannot green a run" "$rc" 0
assert_has   "FM-C4: the receipt still says NO outcome was recorded" "$OUT" "recorded NO outcome"

# ─────────────────────────────────────────────────────────────────────────────
# probe — the rebuild + its own probe pass, and make's second probe finds a
# dead API. The curl at the end of `make deploy` must change the receipt AND
# the exit code instead of being laundered into ">> Warming up".
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(make_deploy STUB_CURL_CODES="200 dead dead")
echo "--- probe (deploy-rebuild 200, make's own probe dead) rc=$rc ---"; grep '^>>' "$OUT" || true
assert_rc_ne "probe: make deploy exits non-zero when the API does not answer 200" "$rc" 0
assert_has   "probe: the receipt names the unverified deploy"                     "$OUT" "DEPLOY UNVERIFIED"
assert_lacks "probe: it does NOT claim the API is live"                           "$OUT" "API is live"
assert_lacks "probe: the old laundering string is gone"                           "$OUT" "Warming up"

# ─────────────────────────────────────────────────────────────────────────────
# happy — green must still be REACHABLE, and it must be a measured green.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(make_deploy STUB_CURL_CODES="200 200")
echo "--- happy (everything answers 200) rc=$rc ---"; grep '^>>' "$OUT" || true
assert_rc  "happy: make deploy exits 0 when every claim was measured" "$rc" 0
assert_has "happy: deploy-rebuild says it restarted AND answered"     "$OUT" "restarted and answering"
assert_has "happy: the receipt cites the recorded hook outcome"       "$OUT" "recorded outcome: rebuilt"
assert_has "happy: the receipt cites the measured status code"        "$OUT" "/api/schemas -> HTTP 200"
if [ ! -s "$DANGER" ]; then ok "happy: no nested make/go escaped the stub PATH"; else bad "happy: escape recorded: $(cat "$DANGER")"; fi

# ─────────────────────────────────────────────────────────────────────────────
# build-fail — THE CONTROL. This path already refused correctly before this
# slice and must be byte-for-byte untouched. It is the only arm expected green
# in BOTH the fail-before and the fail-after run.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(rebuild STUB_MIX_FAIL=compile STUB_CURL_CODES="200 200")
echo "--- build-fail control rc=$rc ---"; tail -2 "$OUT"
assert_rc    "build-fail: exits 1, as it always did" "$rc" 1
assert_has   "build-fail: the original refusal string is byte-for-byte intact" "$OUT" \
             "[deploy-rebuild] BUILD FAILED — api/_build/prod is untouched and still restartable. NOT restarting."
assert_lacks "build-fail: it never reaches the restart"      "$OUT" "Restarting service..."
assert_lacks "build-fail: it never reaches the health probe" "$OUT" "RESTART UNVERIFIED"
if [ "$(cat "$T/api/_build/prod/marker" 2>/dev/null)" = "OLD" ]; then
  ok "build-fail: the live prod build was not touched"
else
  bad "build-fail: api/_build/prod was modified over a failed build"
fi
if [ ! -s "$CURLLOG" ]; then ok "build-fail: no probe was taken (nothing to probe)"; else bad "build-fail: a probe ran after a failed build"; fi

# ─────────────────────────────────────────────────────────────────────────────
# migrate-fail — the other fail-closed path keeps its own typed exit.
# ─────────────────────────────────────────────────────────────────────────────
new_tree
rc=$(rebuild STUB_MIX_FAIL=ecto.migrate STUB_CURL_CODES="200 200")
echo "--- migrate-fail rc=$rc ---"; tail -2 "$OUT"
assert_rc    "migrate-fail: exits 13, as it always did"       "$rc" 13
assert_has   "migrate-fail: the swap-aborted refusal is intact" "$OUT" "MIGRATE FAILED"
assert_lacks "migrate-fail: it never claims a restart"         "$OUT" "Service restarted"

echo
echo "── hermeticity ──"
if [ -x "$BIN/curl" ] && [ ! -x "$ALLOW/curl" ]; then ok "hermetic: curl resolves ONLY to the stub"; else bad "hermetic: a real curl is reachable"; fi
if [ ! -e "$BIN/go" ] && [ ! -e "$ALLOW/go" ]; then ok "hermetic: go is in neither PATH directory"; else bad "hermetic: go is on the harness PATH"; fi
if [ ! -e "$BIN/systemd" ] && [ -x "$BIN/systemctl" ]; then ok "hermetic: systemctl resolves ONLY to the stub"; else bad "hermetic: systemctl is not stubbed"; fi

echo
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "OK — $PASS/$TOTAL checks: every deploy receipt descends from a measurement or refuses."
  exit 0
fi
echo "FAILED: $FAIL of $TOTAL check(s) — a deploy receipt asserts something nobody observed.$FAILED_NAMES"
exit 1
