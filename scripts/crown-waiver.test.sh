#!/usr/bin/env bash
# crown-waiver.test.sh — the two-direction proof for the DATED, SELF-EXPIRING
# waiver in scripts/crown-reconcile.sh.
#
# WHAT IS UNDER TEST. One sha — 28f8e109c58c285f3fd60d6645b4df20467c05e6 — is
# a pre-fix specimen of the forward-only crown-recorder fix (#16471), which
# cannot backfill a row that was already lost. The honest remedy is an
# owner-only backfill (task-9c8fccd9e8a77773). Until then the waiver suppresses
# that ONE sha's GRACED-UNRECORDED finding, LOUDLY, until a hardcoded instant.
#
# A WAIVER IS ONLY WORTH ITS TWO NEGATIVES, so this harness never asserts "it
# was quiet". Every green arm below is paired with a red arm that differs by ONE
# thing:
#
#   (A) clock BEFORE expiry, only the waived sha unrecorded   → exit 0, WAIVED
#   (B) the SAME clock, a DIFFERENT unrecorded sha added      → exit 1
#       (the waiver is narrow: it names one sha literally and
#        cannot cover a second one)
#   (C) clock AFTER expiry, the same lone waived sha          → exit 1
#       (the waiver is inert with no code change)
#
# AND THE PLATFORM IS ITSELF A FIXTURE. `date -u -d ""` returns rc 1 on BSD and
# rc 0 WITH TODAY'S MIDNIGHT on GNU; GNU also accepts a relative grammar ("next
# year") that BSD refuses. A time-gated waiver parsed without a shape check is
# therefore INERT on a mac and LIVE — possibly for a year — on the CI runner.
# Asserting that on whichever date(1) this box happens to have would prove
# nothing, so the harness ships BOTH: a GNU-shaped and a BSD-shaped date(1),
# each implemented over the real one, and runs the same probes under each.
#
#   (D) the two shims genuinely DISAGREE about junk (else every
#       platform arm below is vacuous)
#   (E) the SHIPPED script, expiry constant mutated to GNU-only
#       grammar: INERT under BOTH date(1)s — it fails closed
#   (F) a NO-GUARD mutant, same constant: WAIVED under GNU and
#       INERT under BSD — the divergence the shape check removes
#
#   bash scripts/crown-waiver.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CR="${CROWN_RECONCILE_SH:-$REPO_ROOT/scripts/crown-reconcile.sh}"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()      { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()     { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required (section F builds its mutant with it)" >&2; exit 2; }
[ -f "$CR" ] || { echo "missing $CR" >&2; exit 2; }

# ── the constants, DERIVED from the script and never re-typed ────────────────
# A harness that re-types the sha and the expiry cannot notice them changing.
# An underivable constant is a hard failure: an empty needle matches anything.
WSHA="$(sed -n 's/^WAIVED_SHA="\([^"]*\)".*/\1/p' "$CR" | head -1)"
WEXP="$(sed -n 's/^WAIVER_EXPIRES_ISO="\([^"]*\)".*/\1/p' "$CR" | head -1)"
[ -n "$WSHA" ] || { echo "could not derive WAIVED_SHA from $CR" >&2; exit 2; }
[ -n "$WEXP" ] || { echo "could not derive WAIVER_EXPIRES_ISO from $CR" >&2; exit 2; }

# Portable ISO→epoch for the harness itself (the host may be either platform).
h_epoch() { date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null; }

WEXP_EPOCH="$(h_epoch "$WEXP")"
[ -n "$WEXP_EPOCH" ] || { echo "WAIVER_EXPIRES_ISO ($WEXP) is not parseable by either date(1)" >&2; exit 2; }

# The clocks. Both sit inside the sha's 86400s re-ask retirement, so the ONLY
# difference between the (A) and (C) arms is which side of the expiry they are
# on — not whether the sha is still on the list.
NOW_BEFORE="$(date -u -r "$((WEXP_EPOCH - 1800))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((WEXP_EPOCH - 1800))" +%Y-%m-%dT%H:%M:%SZ)"
NOW_AFTER="$(date -u -r "$((WEXP_EPOCH + 180))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((WEXP_EPOCH + 180))" +%Y-%m-%dT%H:%M:%SZ)"
# First-seen for every graced sha on the seeded list: 8h before the expiry, so
# gage stays well under REASK_MAX_SECONDS on BOTH clocks.
FIRST_SEEN=$((WEXP_EPOCH - 28800))
IN1="$(date -u -r "$((WEXP_EPOCH - 21600))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((WEXP_EPOCH - 21600))" +%Y-%m-%dT%H:%M:%SZ)"
IN2="$(date -u -r "$((WEXP_EPOCH - 18000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((WEXP_EPOCH - 18000))" +%Y-%m-%dT%H:%M:%SZ)"

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
SHA_OTHER="dddddddddddddddddddddddddddddddddddddddd"

fixture_ok() { # <path>
  [ -s "$1" ] && return 0
  echo "FIXTURE WRITE FAILED (out of disk?): $1 is empty — every verdict below would be an unnamed exit 2" >&2
  exit 2
}

# ── fixtures: two delivering runs, both recorded, box serving a recorded sha ──
RUNS="$TMP/runs.json"
printf '{"workflow_runs":[{"id":1,"head_sha":"%s","conclusion":"success","status":"completed","created_at":"%s"},{"id":2,"head_sha":"%s","conclusion":"success","status":"completed","created_at":"%s"}]}' \
  "$SHA_A" "$IN1" "$SHA_B" "$IN2" > "$RUNS"; fixture_ok "$RUNS"
JOBS="$TMP/jobs.json"
printf '{"1":[{"name":"changes","conclusion":"success"},{"name":"control-plane","conclusion":"success"},{"name":"instance","conclusion":"success"}],"2":[{"name":"changes","conclusion":"success"},{"name":"control-plane","conclusion":"success"},{"name":"instance","conclusion":"success"}]}' > "$JOBS"; fixture_ok "$JOBS"
CROWN="$TMP/crown.json"
printf '[{"sha":"%s","target":"cp","carried":false,"first_seen_at":"%s","delivering_run_id":"1"},{"sha":"%s","target":"instance","carried":false,"first_seen_at":"%s","delivering_run_id":"1"},{"sha":"%s","target":"instance","carried":false,"first_seen_at":"%s","delivering_run_id":"2"}]' \
  "$SHA_A" "$IN1" "$SHA_A" "$IN1" "$SHA_B" "$IN2" > "$CROWN"; fixture_ok "$CROWN"
HEALTH="$TMP/health.json"
printf '{"serving_sha":"%s","serving_since":"%s","git_sha":"%s"}' "$SHA_A" "$IN1" "$SHA_A" > "$HEALTH"; fixture_ok "$HEALTH"
# NEITHER the waived sha NOR SHA_OTHER has a cp row in that crown, which is what
# makes both of them accusable — the waiver is the only thing that can differ.

# ── the sandboxes: exactly the tools the script may see, and a date(1) each ──
mk_farm() { # <dir>
  mkdir -p "$1"
  for t in awk basename bash cat cp date dirname grep head install jq mkdir mktemp mv printf rm sed sort tail tr wc; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -sf "$p" "$1/$t"
  done
}
REAL_DATE="$(command -v date)"
FARM="$TMP/farm";      mk_farm "$FARM"
FARM_GNU="$TMP/gnu";   mk_farm "$FARM_GNU"
FARM_BSD="$TMP/bsd";   mk_farm "$FARM_BSD"

# Both shims do their real arithmetic through the HOST's date(1), whichever it
# is, and differ only in the command-line SURFACE they expose — so each arm below
# means the same thing on a mac and on a runner.
cat > "$TMP/core.sh" <<'CORE'
REAL="__REAL__"
core_epoch() { # <iso8601 with T and optional Z>
  local plain="${1%Z}"; plain="${plain%%.*}"
  "$REAL" -u -d "$plain" +%s 2>/dev/null && return 0
  "$REAL" -u -j -f "%Y-%m-%dT%H:%M:%S" "$plain" +%s 2>/dev/null && return 0
  return 1
}
core_iso() { # <epoch> <+format>
  "$REAL" -u -r "$1" "$2" 2>/dev/null && return 0
  "$REAL" -u -d "@$1" "$2" 2>/dev/null && return 0
  return 1
}
core_now() { "$REAL" -u +%s; }
CORE
sed -i.bak "s|__REAL__|$REAL_DATE|" "$TMP/core.sh" && rm -f "$TMP/core.sh.bak"

# mk_farm SYMLINKED a date into each farm. Writing a shim over that symlink
# would follow it and truncate the SYSTEM date(1) — or, where the system
# protects it, fail and silently leave the real one in place, which is how both
# "platform" farms once ran the HOST's date and every platform arm below meant
# nothing. Unlink first, then assert each shim is a REGULAR file.
rm -f "$FARM_GNU/date" "$FARM_BSD/date"

# GNU-SHAPED date(1). Accepts -d, including the relative grammar and the empty
# string (rc 0, today's midnight). Refuses BSD's -j and treats -r as a FILE
# reference, which an epoch number is not.
{
  echo '#!/usr/bin/env bash'
  echo "source \"$TMP/core.sh\""
  cat <<'GNU'
[ "${1:-}" = "-u" ] || exit 1
shift
case "${1:-}" in
  -j) exit 1 ;;
  -r) exit 1 ;;
  -d)
    spec="${2:-}"; fmt="${3:-+%s}"
    case "$spec" in
      @*) core_iso "${spec#@}" "$fmt" ;;
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) e="$(core_epoch "$spec")" || exit 1
         case "$fmt" in +%s) printf '%s\n' "$e" ;; *) core_iso "$e" "$fmt" ;; esac ;;
      "")            e=$(( $(core_now) - $(core_now) % 86400 ))
         case "$fmt" in +%s) printf '%s\n' "$e" ;; *) core_iso "$e" "$fmt" ;; esac ;;
      "next year")   e=$(( $(core_now) + 31536000 ))
         case "$fmt" in +%s) printf '%s\n' "$e" ;; *) core_iso "$e" "$fmt" ;; esac ;;
      *) exit 1 ;;
    esac ;;
  +%s) core_now ;;
  *) exit 1 ;;
esac
GNU
} > "$FARM_GNU/date"
chmod +x "$FARM_GNU/date"

# BSD-SHAPED date(1). No parsing -d at all, -j -f for input, -r for an epoch.
{
  echo '#!/usr/bin/env bash'
  echo "source \"$TMP/core.sh\""
  cat <<'BSD'
[ "${1:-}" = "-u" ] || exit 1
shift
case "${1:-}" in
  -d) exit 1 ;;
  -j)
    [ "${2:-}" = "-f" ] || exit 1
    [ "${3:-}" = "%Y-%m-%dT%H:%M:%S" ] || exit 1
    case "${4:-}" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
      *) exit 1 ;;
    esac
    e="$(core_epoch "${4}")" || exit 1
    case "${5:-+%s}" in +%s) printf '%s\n' "$e" ;; *) core_iso "$e" "${5}" ;; esac ;;
  -r) core_iso "${2:-}" "${3:-+%s}" ;;
  +%s) core_now ;;
  *) exit 1 ;;
esac
BSD
} > "$FARM_BSD/date"
chmod +x "$FARM_BSD/date"

for f in "$FARM_GNU/date" "$FARM_BSD/date"; do
  if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -x "$f" ]; then
    echo "SHIM NOT INSTALLED: $f is not an executable regular file — the platform arms would be running the host's own date(1)" >&2
    exit 2
  fi
done

seed_state() { # <path> <sha>...
  local f="$1"; shift
  printf '# crown-reconcile re-ask list — "<sha> <first-seen-epoch>".\n' > "$f"
  for s in "$@"; do printf '%s %s\n' "$s" "$FIRST_SEEN" >> "$f"; done
}

N=0
run_cr() { # <farm> <script> <now> <expected-rc> <label> <sha-on-list>...
  local farm="$1" script="$2" now="$3" want="$4" label="$5"; shift 5
  local out rc state
  N=$((N + 1))
  state="$TMP/state-$N.txt"
  seed_state "$state" "$@"
  out="$(env -u CROWN_API_TOKEN -u CP_HOST -u DEPLOY_SSH_KEY \
    PATH="$farm" CROWN_STATE_FILE="$state" \
    bash "$script" --now "$now" --window-hours 24 \
      --runs-fixture "$RUNS" --jobs-fixture "$JOBS" \
      --crown-fixture "$CROWN" --health-fixture "$HEALTH" 2>&1)"
  rc=$?
  printf '%s\n' "$out" > "$TMP/last.out"
  if [ "$rc" = "$want" ]; then ok "$label → exit $rc"
  else bad "$label → exit $rc, wanted $want"; printf '%s\n' "$out" | sed 's/^/       | /' >&2; fi
  return 0
}
saw()     { if grep -qF "$1" "$TMP/last.out"; then ok "$2"; else bad "$2 — the output never said: $1"; sed 's/^/       | /' "$TMP/last.out" >&2; fi; }
not_saw() { if grep -qF "$1" "$TMP/last.out"; then bad "$2 — the output said: $1"; sed 's/^/       | /' "$TMP/last.out" >&2; else ok "$2"; fi; }

section "(0) the waiver's own constants — a ceiling, a shape, and one literal sha"
case "$WSHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
    ok "the waived sha is a full 40-char hex literal, not a prefix or a pattern: $WSHA" ;;
  *) bad "WAIVED_SHA is not a full 40-char sha — a short or patterned value can suppress more than one finding: $WSHA" ;;
esac
case "$WEXP" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
    ok "the expiry is an unambiguous UTC instant: $WEXP" ;;
  *) bad "WAIVER_EXPIRES_ISO is not exactly YYYY-MM-DDTHH:MM:SSZ: $WEXP" ;;
esac
# THE CEILING. The condition being excused retires on its own at the sha's
# 86400s REASK_MAX_SECONDS age-off (first seen 2026-09-06T08:32:19Z). A waiver
# that outlived that would be excusing something that is no longer happening.
CEILING="$(h_epoch "2026-09-07T08:32:00Z")"
if [ "$WEXP_EPOCH" -le "$CEILING" ]; then
  ok "the expiry is at or before the 86400s dirty retirement (2026-09-07T08:32:00Z) — it cannot outlive the condition it excuses"
else
  bad "the expiry $WEXP is AFTER 2026-09-07T08:32:00Z — the waiver would outlive the finding it waives"
fi
# These needles are LITERAL script text, so single quotes are the point.
# shellcheck disable=SC2016
if grep -q '\[ "\$1" = "\$WAIVED_SHA" \] || return 1' "$CR"; then
  ok "the sha test is string EQUALITY — no prefix, no glob, no regex"
else
  bad "$CR does not compare the sha with a plain string equality — the waiver may be wider than one sha"
fi
if grep -qF 'task-9c8fccd9e8a77773' "$CR"; then ok "the script names who owns the real remedy"; else bad "the waiver does not name the owner-queue backfill that actually settles the debt"; fi
if grep -qF '#16471' "$CR"; then ok "the script names the forward-only fix this sha predates"; else bad "the waiver never explains WHY this sha is a specimen"; fi

for pair in "REAL:$FARM" "GNU:$FARM_GNU" "BSD:$FARM_BSD"; do
  plat="${pair%%:*}"; farm="${pair#*:}"

  section "(A) $plat — clock BEFORE expiry: the waived sha is not a red, and says so out loud"
  run_cr "$farm" "$CR" "$NOW_BEFORE" 0 "[$plat] only $WSHA is unrecorded, and the clock is before $WEXP" "$WSHA"
  saw "WAIVED (expires $WEXP" "[$plat] the run NAMES the waived sha and the instant the waiver dies"
  saw "$WSHA" "[$plat] and it names the sha itself — nobody reads a silent green"
  saw "GRACED-WAIVED: 1 sha(s)" "[$plat] the verdict block counts the waiver rather than hiding it"
  not_saw "GRACED-UNRECORDED" "[$plat] the accusation does not fire while the waiver is live"

  section "(B) $plat — the SAME clock, one MORE unrecorded sha: the waiver is narrow"
  run_cr "$farm" "$CR" "$NOW_BEFORE" 1 "[$plat] $SHA_OTHER is graced-unrecorded too and is NOT covered" "$WSHA" "$SHA_OTHER"
  saw "GRACED-UNRECORDED: 1 sha(s)" "[$plat] exactly one sha is accused — the waiver suppressed one, not both"
  saw "$SHA_OTHER" "[$plat] and the accused one is the sha the waiver was not written for"
  saw "graced-unrecorded=1" "[$plat] the verdict axis moves with it"
  saw "WAIVED (expires $WEXP" "[$plat] the waived sha is still announced in the same run"

  section "(C) $plat — clock AFTER expiry: the waiver is inert, with no code change"
  run_cr "$farm" "$CR" "$NOW_AFTER" 1 "[$plat] the same lone sha, ${NOW_AFTER} — past $WEXP" "$WSHA"
  saw "GRACED-UNRECORDED: 1 sha(s)" "[$plat] the accusation returns by itself"
  saw "$WSHA" "[$plat] and it names the sha the waiver used to cover"
  not_saw "WAIVED (expires" "[$plat] nothing is waived past the expiry instant"
  not_saw "GRACED-WAIVED" "[$plat] and the waiver's own summary line is gone too"
done

section "(D) the two shims genuinely DISAGREE about junk — else every platform arm above is vacuous"
if (PATH="$FARM_GNU"; date -u -d "" +%s >/dev/null 2>&1); then
  ok "the GNU shim accepts \`date -u -d ''\` (rc 0) — the hazard is reproduced here"
else
  bad "the GNU shim REFUSES \`date -u -d ''\` — it does not emulate GNU, so the platform arms prove nothing"
fi
if (PATH="$FARM_BSD"; date -u -d "" +%s >/dev/null 2>&1); then
  bad "the BSD shim ACCEPTS \`date -u -d ''\` — it does not emulate BSD, so the divergence is not being modelled"
else
  ok "the BSD shim refuses \`date -u -d ''\` (rc 1) — the two date(1)s disagree about junk, as the real ones do"
fi
if (PATH="$FARM_GNU"; date -u -d "next year" +%s >/dev/null 2>&1); then
  ok "the GNU shim accepts the relative grammar \`next year\`"
else
  bad "the GNU shim rejects \`next year\` — the (F) mutant below cannot demonstrate a far-future expiry"
fi

section "(E) the SHIPPED script with a GNU-ONLY expiry constant fails CLOSED on both platforms"
MUT_GUARDED="$TMP/cr-mut-guarded.sh"
sed "s|^WAIVER_EXPIRES_ISO=\".*\"|WAIVER_EXPIRES_ISO=\"next year\"|" "$CR" > "$MUT_GUARDED"
if grep -q '^WAIVER_EXPIRES_ISO="next year"$' "$MUT_GUARDED"; then
  ok "the mutation APPLIED — the constant really is GNU-only grammar in this copy"
else
  bad "the mutation did NOT apply; the two arms below would be testing the shipped constant"
fi
run_cr "$FARM_GNU" "$MUT_GUARDED" "$NOW_BEFORE" 1 "[GNU] a malformed expiry waives NOTHING" "$WSHA"
saw "WAIVER INERT" "[GNU] and it says so — an unusable constant is announced, not silently honoured"
saw "GRACED-UNRECORDED: 1 sha(s)" "[GNU] the sha is judged normally"
run_cr "$FARM_BSD" "$MUT_GUARDED" "$NOW_BEFORE" 1 "[BSD] the same copy, the same verdict" "$WSHA"
saw "WAIVER INERT" "[BSD] the same announcement"
saw "GRACED-UNRECORDED: 1 sha(s)" "[BSD] the same accusation — the shape check makes the verdict platform-independent"

section "(F) …and WITHOUT the shape check the same constant splits the two platforms"
# The whole reason the guard exists, run rather than argued: strip the shape
# check, hand the parse straight to date(1), and the identical script waives for
# a YEAR on a runner while looking perfectly inert on a mac.
MUT_NOGUARD="$TMP/cr-mut-noguard.sh"
python3 - "$MUT_GUARDED" "$MUT_NOGUARD" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
start = s.index('case "$WAIVER_EXPIRES_ISO" in')
end = s.index('esac', s.index('esac', start) + 4) + len('esac')
naive = 'WAIVER_EXPIRES_EPOCH="$(date -u -d "$WAIVER_EXPIRES_ISO" +%s 2>/dev/null || true)"\n: '
open(sys.argv[2], 'w').write(s[:start] + naive + s[end:])
PY
# shellcheck disable=SC2016
if grep -q 'WAIVER_EXPIRES_EPOCH="$(date -u -d "$WAIVER_EXPIRES_ISO"' "$MUT_NOGUARD" \
   && ! grep -q 'case "$WAIVER_EXPIRES_ISO" in' "$MUT_NOGUARD" \
   && bash -n "$MUT_NOGUARD"; then
  ok "the no-guard mutant APPLIED and parses — the shape check is gone, the parse is naive"
else
  bad "the no-guard mutation did not apply cleanly; the two arms below prove nothing"
fi
run_cr "$FARM_GNU" "$MUT_NOGUARD" "$NOW_BEFORE" 0 "[GNU] naive parse of 'next year' → a FUTURE expiry, the sha is waived" "$WSHA"
saw "WAIVED (expires next year" "[GNU] the unguarded waiver is LIVE off a constant nobody can date"
run_cr "$FARM_BSD" "$MUT_NOGUARD" "$NOW_BEFORE" 1 "[BSD] the SAME file, the SAME constant → inert, the sha is accused" "$WSHA"
saw "GRACED-UNRECORDED: 1 sha(s)" "[BSD] one script, two date(1)s, two opposite verdicts — which is exactly what the shape check removes"

# ── ZERO PROBES IS A PASS IN EVERY RUNNER ────────────────────────────────────
# Every arm above is written out by hand, so this floor guards the failure mode
# where a `set -e`, an early `exit`, or a botched edit silences most of the file
# and the summary still prints 0 failures.
FLOOR=60
TOTAL=$((PASS + FAIL))
echo
if [ "$TOTAL" -lt "$FLOOR" ]; then
  echo "FLOOR: only $TOTAL assertion(s) ran, fewer than the $FLOOR this harness contains — something exited early and a green here would be silence, not coverage." >&2
  FAIL=$((FAIL + 1))
fi
echo "crown-waiver: $PASS passed, $FAIL failed ($TOTAL assertions, floor $FLOOR)"
[ "$FAIL" -eq 0 ] || exit 1
