#!/bin/sh
#
# console-runtime-pin-check.sh — the console harness declares the Node it is
# tested under, and this proves the workflow still honours that declaration.
#
# WHAT IT PINS (Cloud Console Hardening wave 61)
# ---------------------------------------------
#   · cloud/priv/static/__node-version — the CONSOLE-LOCAL declaration (a bare
#     major, currently 20). It lives beside __app.test.mjs because that is what
#     it describes.
#   · console-harness.yml's `console-unit` job must carry that SAME literal in
#     `node-version:`.
#   · The EXEMPTION SET is pinned by SET-EQUALITY, not by a floor: exactly
#     `cssom-parity`, `tier-floor-render`, `overflow-guard` and `modal-oracle`
#     may differ, and they must all be on 22 (they speak CDP over a bare global
#     WebSocket, stable by default only from Node 22 — epic decision D17). A
#     FIFTH setup-node job reds this guard and is NAMED, because a new job
#     silently inheriting a different runtime is exactly the drift nobody would
#     see. `modal-oracle` joined on 2026-09-05
#     (cch-w22-s1-residue-modal-oracle-uninvoked): it is the fourth CDP
#     instrument to get its own job, and it needs 22 for the same reason the
#     other three do — this guard REDS a new browser job rather than letting it
#     inherit a runtime on which its bring-up exits 2, which is the guard
#     working, not the guard in the way.
#
# WHY A REPO-ROOT .nvmrc WOULD BE WRONG
# -------------------------------------
# The repo runs a MIXED fleet: 33 `node-version:` entries across 25 workflows,
# roughly half on 20 and half on 22. A root declaration would OVERCLAIM — it
# would state something true of one harness as though it were true of the fleet,
# which is the exact species of unmeasured claim this epic exists to delete.
#
# WHY `console-unit` KEEPS A LITERAL AND IS **NOT** MOVED TO `node-version-file:`
# ------------------------------------------------------------------------------
# `node-version-file: cloud/priv/static/__node-version` looks tidier and it
# DESTROYS this guard: the parity leg becomes "the file equals itself" — true by
# construction, unable to lose, exactly a vacuous green. Two independent
# statements plus a check that they agree is the whole instrument. This script
# therefore REFUSES a `node-version-file:` on `console-unit`.
#
# WHAT THIS DOES **NOT** PIN — stated so nobody reads more into a green than it
# carries:
#   · It measures `.github/workflows/console-harness.yml` ONLY. The other 24
#     workflows are outside its universe and it says nothing about them.
#   · It does NOT close the TDZ class. "node 20 runs tests during evaluation,
#     node >=22 defers" was REFUTED BY MEASUREMENT (node 22 TDZ-crashes a probe
#     planted at the same anchor; a 10-test synthetic fails on BOTH). The real
#     mechanism is a DRAIN RACE whose depth varies with runtime version, queue
#     length and how much async work the awaited import does. Pinning the
#     runtime NARROWS the window; only scripts/console-tdz-order-check.mjs
#     closes the class. A green here is hygiene, never a TDZ verdict.
#
# USAGE
#   sh scripts/console-runtime-pin-check.sh              # measure the tree
#   sh scripts/console-runtime-pin-check.sh --selftest   # prove it can lose
#
# EXIT: 0 agreed · 1 drift (named) · 2 refused to measure.

ROOT="${CONSOLE_RUNTIME_PIN_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
DECL_REL="cloud/priv/static/__node-version"
WF_REL=".github/workflows/console-harness.yml"
PINNED_JOB="console-unit"
EXEMPT_JOBS="cssom-parity modal-oracle overflow-guard tier-floor-render"   # sorted
EXEMPT_VERSION="22"

fail() { echo "::error::console-runtime-pin-check: $*" >&2; }

# Every `node-version:` / `node-version-file:` in the workflow, attributed to the
# job header above it. COMMENT LINES ARE SKIPPED — console-harness.yml:600
# carries the string `node-version: 20` inside a prose comment, and a naive grep
# attributes it to whichever job it lands near.
# A job header may carry a TRAILING COMMENT (`  intruder-job:  # added in a
# hurry`). The old anchored `:[[:space:]]*$` missed those headers entirely, so
# the setup-node underneath was attributed to the PREVIOUS matched header — an
# intruder placed above `cssom-parity` was silently absorbed into the pinned set.
pairs() {
  awk '
    /^[[:space:]]*#/                              { next }
    /^  [A-Za-z0-9_-]+:[[:space:]]*(#.*)?$/       { j=$0; sub(/^  /,"",j); sub(/:.*$/,"",j); next }
    /node-version-file:/                          { print j "\tFILE"; next }
    /node-version:/                               { v=$0; sub(/^.*node-version:[[:space:]]*/,"",v);
                                                    gsub(/[^0-9A-Za-z._-]/,"",v); print j "\t" v }
  ' "$1"
}

measure() {
  decl_path="$ROOT/$DECL_REL"
  wf_path="$ROOT/$WF_REL"
  rc=0

  if [ ! -f "$wf_path" ]; then
    fail "REFUSED TO MEASURE — $WF_REL is missing under $ROOT."
    return 2
  fi
  if [ ! -f "$decl_path" ]; then
    fail "REFUSED TO MEASURE — the console runtime declaration $DECL_REL is missing. It is what console-unit's literal is checked against; without it this guard would pass by having nothing to compare."
    return 2
  fi

  decl="$(tr -d ' \t\r\n' < "$decl_path")"
  case "$decl" in
    ''|*[!0-9]*)
      fail "REFUSED TO MEASURE — $DECL_REL must be a bare major version (e.g. 20); got '$decl'."
      return 2
      ;;
  esac

  rows="$(pairs "$wf_path")"
  if [ -z "$rows" ]; then
    fail "REFUSED TO MEASURE — no node-version entry found in $WF_REL. Either the workflow changed shape or this parser went blind; a guard that finds nothing must not report agreement."
    return 2
  fi

  echo "console-runtime-pin-check: declaration $DECL_REL = $decl"
  echo "console-runtime-pin-check: setup-node roster in $WF_REL"
  echo "$rows" | while IFS="$(printf '\t')" read -r j v; do echo "    $j -> $v"; done

  observed="$(echo "$rows" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  expected="$(printf '%s %s\n' "$PINNED_JOB" "$EXEMPT_JOBS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ *$//')"

  # SET-EQUALITY, both directions. An intruder and a disappearance are both drift.
  if [ "$observed" != "$expected" ]; then
    for j in $observed; do
      case " $expected " in *" $j "*) ;; *)
        fail "INTRUDER — job '$j' declares a node-version but is not in the pinned set. Add it to this guard (and say why it needs its own runtime) or drop its setup-node. Pinned: $expected." ;;
      esac
    done
    for j in $expected; do
      case " $observed " in *" $j "*) ;; *)
        fail "MISSING — pinned job '$j' no longer declares a node-version. If the job is gone, retire it here; if it just lost its setup-node, it is now on the runner default and nothing states which." ;;
      esac
    done
    rc=1
  fi

  # DUPLICATE — a job may state its runtime ONCE. The set-equality leg above
  # reasons over `sort -u` job NAMES, so a second `node-version` row on an
  # already-known job used to be printed to the roster and then dropped from
  # every verdict. This guard reads a job's runtime from its declaration; with
  # two declarations and no tiebreak it cannot know which runtime actually runs,
  # so it refuses to certify either. (It does NOT claim "the last one wins" —
  # that was not measured here, and the refusal does not need it.)
  for j in $(echo "$rows" | cut -f1 | sort | uniq -d); do
    vals="$(echo "$rows" | awk -F'\t' -v j="$j" '$1 == j { print $2 }' | tr '\n' ' ' | sed 's/ *$//')"
    fail "DUPLICATE — job '$j' declares node-version more than once (values: $vals). This guard names a job's runtime from its declaration; with two declarations and no tiebreak it cannot know which runtime this job actually runs on, so it refuses to certify either one. Leave exactly one."
    rc=1
  done

  # Every value the pinned job declares, not just the first — a `node-version-file:`
  # added BELOW the literal used to slip past the headline refusal.
  pinned_vals="$(echo "$rows" | awk -F'\t' -v j="$PINNED_JOB" '$1 == j { print $2 }')"
  if [ -z "$pinned_vals" ]; then
    fail "'$PINNED_JOB' declares no node-version — the harness would run on the runner default and no file would say so."
    rc=1
  else
    for v in $pinned_vals; do
      if [ "$v" = "FILE" ]; then
        fail "REFUSED — '$PINNED_JOB' uses node-version-file:. That makes this guard's parity leg compare the declaration with itself: true by construction, unable to lose. Keep the literal."
        rc=1
      elif [ "$v" != "$decl" ]; then
        fail "PARITY — $DECL_REL says $decl but '$PINNED_JOB' runs node-version: $v. The harness is tested under a runtime nothing declares."
        rc=1
      fi
    done
  fi

  for j in $EXEMPT_JOBS; do
    vals="$(echo "$rows" | awk -F'\t' -v j="$j" '$1 == j { print $2 }')"
    [ -n "$vals" ] || continue   # absence already reported by set-equality
    for v in $vals; do
      if [ "$v" != "$EXEMPT_VERSION" ]; then
        fail "EXEMPTION DRIFT — browser job '$j' is on node-version: $v, not $EXEMPT_VERSION. These three are exempt BECAUSE they need 22 for a stable global WebSocket (D17); on anything else the exemption has lost its reason."
        rc=1
      fi
    done
  done

  [ "$rc" -eq 0 ] && echo "OK: the console runtime declaration, console-unit's literal and the exemption set (printed in full above, never counted in this sentence) all agree."
  return "$rc"
}

# ── SELF-TEST ───────────────────────────────────────────────────────────────
# Ten mutations on a throwaway copy of the tree. Each must red, and the
# unmutated copy must green — a pin that cannot lose is not a pin. The last four
# are wave 62's: they all ran GREEN before this change, because the guard
# reasoned over a SET of job names and then read ONE value per job.
selftest() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  bad=0
  say() { if [ "$2" -eq 0 ]; then echo "  ok  $1"; else echo "  FAIL  $1"; bad=$((bad+1)); fi; }

  fresh() {
    rm -rf "$tmp/tree"
    mkdir -p "$tmp/tree/.github/workflows" "$tmp/tree/cloud/priv/static"
    cp "$ROOT/$WF_REL" "$tmp/tree/$WF_REL"
    cp "$ROOT/$DECL_REL" "$tmp/tree/$DECL_REL"
  }
  probe() { CONSOLE_RUNTIME_PIN_ROOT="$tmp/tree" sh "$0" >"$tmp/out" 2>&1; echo $?; }

  echo "console-runtime-pin-check --selftest (throwaway copy of the tree)"

  fresh; rc="$(probe)"
  [ "$rc" -eq 0 ] && say "clean copy exits 0" 0 || { say "clean copy exits 0 (got $rc)" 1; sed 's/^/      /' "$tmp/out"; }

  fresh; printf '22\n' > "$tmp/tree/$DECL_REL"; rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "PARITY" "$tmp/out" && say "declaration bumped to 22 -> PARITY red" 0 || say "declaration bumped to 22 -> PARITY red (got $rc)" 1

  fresh; sed 's/^          node-version: 20$/          node-version: 22/' "$ROOT/$WF_REL" > "$tmp/tree/$WF_REL"; rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "PARITY" "$tmp/out" && say "console-unit's yml line flipped to 22 -> PARITY red" 0 || say "console-unit's yml line flipped to 22 -> PARITY red (got $rc)" 1

  fresh
  awk '/^  cssom-parity:/ { inj=1 } inj && /node-version: 22/ && !done { sub(/22/,"20"); done=1 } { print }' \
    "$ROOT/$WF_REL" > "$tmp/tree/$WF_REL"
  rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "EXEMPTION DRIFT" "$tmp/out" && say "an exempt browser job drifted to 20 -> EXEMPTION DRIFT red" 0 || say "an exempt browser job drifted to 20 -> EXEMPTION DRIFT red (got $rc)" 1

  fresh; rm -f "$tmp/tree/$DECL_REL"; rc="$(probe)"
  [ "$rc" -eq 2 ] && grep -q "REFUSED TO MEASURE" "$tmp/out" && say "declaration deleted -> REFUSED TO MEASURE (2)" 0 || say "declaration deleted -> REFUSED TO MEASURE (2) (got $rc)" 1

  fresh
  {
    cat "$ROOT/$WF_REL"
    printf '\n  intruder-job:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/setup-node@v4\n        with:\n          node-version: 18\n'
  } > "$tmp/tree/$WF_REL"
  rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "INTRUDER — job 'intruder-job'" "$tmp/out" && say "a FOURTH setup-node job -> INTRUDER red, named" 0 || { say "a FOURTH setup-node job -> INTRUDER red, named (got $rc)" 1; sed 's/^/      /' "$tmp/out"; }

  # ── wave 62: the four holes a set-of-jobs reading left open ────────────────
  # Each of these ran rc=0 on origin/main: the roster PRINTED the contradiction
  # and the script certified agreement anyway.

  fresh
  awk '{ print }
       /^          node-version: 20$/ && !d {
         print "      - uses: actions/setup-node@v4";
         print "        with:";
         print "          node-version: 22";
         d=1 }' "$ROOT/$WF_REL" > "$tmp/tree/$WF_REL"
  rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "DUPLICATE — job 'console-unit'" "$tmp/out" && say "a SECOND setup-node inside console-unit (on 22) -> DUPLICATE red, named" 0 || { say "a SECOND setup-node inside console-unit (on 22) -> DUPLICATE red, named (got $rc)" 1; sed 's/^/      /' "$tmp/out"; }

  fresh
  awk '/^  cssom-parity:/ { inj=1 }
       { print }
       inj && /^          node-version: 22$/ && !d {
         print "      - uses: actions/setup-node@v4";
         print "        with:";
         print "          node-version: 20";
         d=1 }' "$ROOT/$WF_REL" > "$tmp/tree/$WF_REL"
  rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "DUPLICATE — job 'cssom-parity'" "$tmp/out" && grep -q "EXEMPTION DRIFT" "$tmp/out" && say "a SECOND setup-node inside an EXEMPT job (on 20) -> DUPLICATE + EXEMPTION DRIFT red" 0 || { say "a SECOND setup-node inside an EXEMPT job (on 20) -> DUPLICATE + EXEMPTION DRIFT red (got $rc)" 1; sed 's/^/      /' "$tmp/out"; }

  fresh
  awk '{ print }
       /^          node-version: 20$/ && !d {
         print "          node-version-file: cloud/priv/static/__node-version";
         d=1 }' "$ROOT/$WF_REL" > "$tmp/tree/$WF_REL"
  rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "REFUSED — 'console-unit' uses node-version-file" "$tmp/out" && say "node-version-file: added BELOW the literal -> still REFUSED" 0 || { say "node-version-file: added BELOW the literal -> still REFUSED (got $rc)" 1; sed 's/^/      /' "$tmp/out"; }

  fresh
  awk '/^  cssom-parity:/ && !d {
         print "  intruder-job:  # added by a hurried PR";
         print "    runs-on: ubuntu-latest";
         print "    steps:";
         print "      - uses: actions/setup-node@v4";
         print "        with:";
         print "          node-version: 18";
         print "";
         d=1 }
       { print }' "$ROOT/$WF_REL" > "$tmp/tree/$WF_REL"
  rc="$(probe)"
  [ "$rc" -eq 1 ] && grep -q "INTRUDER — job 'intruder-job'" "$tmp/out" && say "an intruder job whose header carries a trailing comment, ABOVE cssom-parity -> INTRUDER red, named" 0 || { say "an intruder job whose header carries a trailing comment, ABOVE cssom-parity -> INTRUDER red, named (got $rc)" 1; sed 's/^/      /' "$tmp/out"; }

  if [ "$bad" -ne 0 ]; then
    fail "SELF-TEST FAILED ($bad assertion(s)) — this pin can no longer lose."
    return 1
  fi
  echo "  self-test: 10/10 — the pin can still lose."
  return 0
}

case "${1:-}" in
  --selftest) selftest ;;
  '') measure ;;
  *) echo "usage: sh scripts/console-runtime-pin-check.sh [--selftest]" >&2; exit 2 ;;
esac
