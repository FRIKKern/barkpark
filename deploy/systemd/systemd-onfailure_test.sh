#!/usr/bin/env bash
# systemd-onfailure_test.sh — every SCHEDULED unit in deploy/systemd has a
# failure handler, and nothing swallows it before it fires.
#
# WHY THIS EXISTS. A timer-driven job on a box that is off-CI by construction
# fails into total silence: the timer keeps firing, the exit code goes to
# journald, and nobody opens journald on a cron. Before this file, `git grep
# OnFailure` over the whole repository returned three hits, all of them Go test
# FUNCTION NAMES in internal/cli — ZERO systemd OnFailure= directives existed
# anywhere in the tree.
#
# THE THREE INVARIANTS
#   A. Every .timer's target .service exists and carries an OnFailure=.
#   B. Every OnFailure= names a handler unit that EXISTS in this directory.
#      (systemd accepts a reference to a unit that was never installed and just
#      logs "not found" at fire time — i.e. exactly when nobody is watching.)
#   C. No scheduled .service carries Restart= with a value other than `no`.
#      This is not style. With Restart= set, systemd enters `failed` — and so
#      fires OnFailure= — only after the restart budget is EXHAUSTED. A
#      Restart=always on a job that never succeeds means the handler never runs
#      at all. Both units guarded today are Type=oneshot with no Restart=, and
#      this arm is what keeps that true.
#
# ANTI-VACUITY, both directions. A "no violations" check over a corpus that
# evaporated is indistinguishable from a pass, so:
#   * MIN_TIMERS is a floor on the discovered corpus (arm D); and
#   * the run PROVES IT CAN FAIL (arm E) by stripping OnFailure= from a COPY of
#     a real unit in a tmpdir and requiring the checker to red on it. No tracked
#     file is ever touched. If the planted defect does NOT red, this script
#     FAILS, because at that moment the green above has stopped meaning
#     anything.
#
# COMMENTS ARE NOT DIRECTIVES. The units carry prose ABOUT OnFailure= in their
# own headers. A naive `grep -q OnFailure` would pass on a unit whose only
# mention is a comment explaining what one would do. Every read here strips
# `#`-comments first — the check would otherwise be green by its own paperwork.
#
# WHAT THIS CANNOT DO. It is a text check. It does not run `systemd-analyze
# verify` (not available on macOS, where much of this repo is authored) and it
# proves nothing about a live box: only that what we would install is coherent.
#
# Usage: bash deploy/systemd/systemd-onfailure_test.sh
#        SYSTEMD_DIR=<dir> bash ...   (used by the arm-E control; not for CI)
set -uo pipefail

DIR="${SYSTEMD_DIR:-$(cd "$(dirname "$0")" && pwd)}"
MIN_TIMERS="${MIN_TIMERS:-2}"
FAILED=0
CHECKS=0

fail() { printf 'FAIL: %s\n' "$1" >&2; FAILED=1; }
ok()   { printf 'ok: %s\n' "$1"; CHECKS=$((CHECKS + 1)); }

# directives <file> — the file with #-comments and blank lines removed.
directives() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }

# value <file> <key> — the value of Key=... , comments stripped, or empty.
value() { directives "$1" | grep -m1 -E "^[[:space:]]*$2=" | sed -E "s/^[[:space:]]*$2=[[:space:]]*//"; }

timers=()
while IFS= read -r t; do [ -n "$t" ] && timers+=("$t"); done < <(ls "$DIR"/*.timer 2>/dev/null)

# ── arm D: the corpus floor ──────────────────────────────────────────────────
if [ "${#timers[@]}" -lt "$MIN_TIMERS" ]; then
  fail "discovered only ${#timers[@]} .timer file(s) in $DIR; the floor is $MIN_TIMERS. A pass over a corpus that shrank is a check that stopped looking, not a green. Lower MIN_TIMERS deliberately if deploy/systemd really lost a timer."
else
  ok "corpus floor: ${#timers[@]} .timer file(s) discovered (floor $MIN_TIMERS)"
fi

for t in "${timers[@]}"; do
  tname="$(basename "$t")"
  # A [Timer] may name its target explicitly with Unit=; otherwise systemd
  # triggers the same-basename .service.
  unit="$(value "$t" Unit)"
  [ -n "$unit" ] || unit="${tname%.timer}.service"
  svc="$DIR/$unit"

  if [ ! -f "$svc" ]; then
    fail "$tname triggers $unit, which is not present in $DIR — the check cannot see whether it is guarded"
    continue
  fi

  # ── arm A: the handler is wired ────────────────────────────────────────────
  handler="$(value "$svc" OnFailure)"
  if [ -z "$handler" ]; then
    fail "$unit is triggered by $tname and carries NO OnFailure= directive. A scheduled job on an off-CI box that fails without a handler fails where nobody is watching. Wire it: OnFailure=barkpark-unit-failure-alert@%n.service — on the .service, NOT on $tname (a timer's OnFailure= fires only when the TIMER fails to activate)."
    continue
  fi
  ok "$unit carries OnFailure=$handler (scheduled by $tname)"

  # ── arm B: the handler it names actually exists here ───────────────────────
  for h in $handler; do
    case "$h" in
      *@%n.service|*@%i.service|*@%N.service) hf="${h%@*}@.service" ;;
      *)                                      hf="$h" ;;
    esac
    if [ -f "$DIR/$hf" ]; then
      ok "$unit's handler $h resolves to $hf, which exists in $DIR"
    else
      fail "$unit names OnFailure=$h but $hf is not in $DIR. systemd accepts a reference to a unit that was never installed and merely logs it at fire time — i.e. the one moment nobody is reading."
    fi
  done

  # ── arm C: nothing swallows the failure before the handler fires ───────────
  restart="$(value "$svc" Restart)"
  if [ -n "$restart" ] && [ "$restart" != "no" ]; then
    fail "$unit is scheduled and sets Restart=$restart. systemd enters 'failed' — and only then fires OnFailure= — after the restart budget is EXHAUSTED, so a restarting job can keep the handler from ever running. Use Restart=no (the default) on a timer-driven job."
  else
    ok "$unit sets no restart policy (Restart='${restart:-<unset>}') — its first failure is final, so OnFailure= fires immediately"
  fi
done

# ── arm E: the firing control — prove this check CAN red ─────────────────────
# The control re-invokes THIS script against the mutated copy. That inner run
# must not run arm E itself, or the recursion never bottoms out — hence the
# variable, which is set ONLY by the control below and is not a user knob.
if [ -n "${BP_ONFAILURE_NO_CONTROL:-}" ]; then
  if [ "$FAILED" -ne 0 ]; then exit 1; fi
  exit 0
fi
ctl="$(mktemp -d)"
trap 'rm -rf "$ctl"' EXIT
cp "$DIR"/*.timer "$DIR"/*.service "$ctl"/ 2>/dev/null
victim=""
for f in "$ctl"/*.service; do
  grep -qE '^[[:space:]]*OnFailure=' "$f" 2>/dev/null && { victim="$f"; break; }
done
if [ -z "$victim" ]; then
  fail "arm E could not run: no unit in the copied corpus carries an OnFailure= to strip, so this script has not proven it can fail."
else
  before="$(grep -cE '^[[:space:]]*OnFailure=' "$victim")"
  sed -i.bak -E '/^[[:space:]]*OnFailure=/d' "$victim" && rm -f "$victim.bak"
  after="$(grep -cE '^[[:space:]]*OnFailure=' "$victim" || true)"
  if [ "$before" -lt 1 ] || [ "$after" -ne 0 ]; then
    fail "arm E's mutation DID NOT APPLY to $(basename "$victim") (OnFailure lines before=$before after=$after). An unapplied mutation is not a catch."
  else
    ctl_out="$(SYSTEMD_DIR="$ctl" MIN_TIMERS="$MIN_TIMERS" BP_ONFAILURE_NO_CONTROL=1 bash "$0" 2>&1)" && ctl_rc=0 || ctl_rc=$?
    if [ "$ctl_rc" -eq 0 ]; then
      fail "arm E: OnFailure= was stripped from a copy of $(basename "$victim") and this check STILL PASSED. The green above proves nothing — find out why (a comment being counted as a directive, a glob that matched nothing, a stripped read)."
    # NOT `printf ... | grep -q`. grep -q exits on its first match, SIGPIPEs the
    # printf, and under `set -o pipefail` the pipeline returns 141 — so a control
    # that fired CORRECTLY is read as "fired for the wrong reason". Measured here
    # on the first run of this file. A case-glob touches no pipe.
    elif case "$ctl_out" in *"carries NO OnFailure= directive"*) false ;; *) true ;; esac; then
      fail "arm E fired for the WRONG REASON (exit $ctl_rc) — the output names no missing-OnFailure violation, so the control is not measuring what it claims. Output: $ctl_out"
    else
      ok "control: stripping OnFailure= from a copy of $(basename "$victim") reds this check (exit $ctl_rc, the missing-handler arm named it) — the result above is a measurement, not an absence of one"
    fi
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  printf '\nsystemd-onfailure_test.sh: FAILED (%d checks passed before the failure(s) above)\n' "$CHECKS" >&2
  exit 1
fi
printf '\nsystemd-onfailure_test.sh: PASS — %d checks over %d scheduled unit(s)\n' "$CHECKS" "${#timers[@]}"
