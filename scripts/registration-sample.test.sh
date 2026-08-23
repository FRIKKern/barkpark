#!/usr/bin/env bash
#
# registration-sample.test.sh — the harness that proves the sampler can REFUSE.
#
# A sampler that only ever agrees is not an instrument, it is a rubber stamp,
# and the decision it guards (registering `Console gate` / `Cloud gate` as
# required contexts) deadlocks main forever if it is wrong. So every case here
# is a MUTATION of one clean fixture set, and each mutant must red for its OWN
# reason and only its own reason:
#
#   CONTROL   unmutated fixtures CLEAR (exit 0) — so the plants' reds are the
#             mutations, not the harness.
#   PLANT A   a dropped `Cloud gate` on a head whose run CONCLUDED success.
#             The count bar is STILL satisfied afterwards; the refusal must come
#             from the shim-defect counter alone. This is the case a
#             count-only bar cannot see.
#   PLANT B   every NEITHER-shape qualifier reshaped into a CLOUD-shape one.
#             The count bar is STILL satisfied (4 qualifying); the refusal must
#             come from the shape clause alone.
#   PLANT C   every run set to in_progress. Heads must be counted UNSETTLED —
#             excluded from numerator AND denominator — never reported ABSENT,
#             and never reported as shim defects.
#
# The fixtures also carry, in the CONTROL, two DISTINCT absence causes on
# non-qualifying heads (NO-RUN and CADENCE) so the four-cause classifier is
# exercised by the green case, not only by the reds.
#
# Path classification is NOT mocked: the fixtures feed real changed-path lists
# through the real `console-path-escape-check.sh --match` /
# `cloud-path-escape-check.sh --match`, because a sampler that agreed with a
# mocked path set and disagreed with the dispatcher would be worse than no
# sampler at all.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/registration-sample.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   — $1"; }
no() { fail=$((fail + 1)); echo "  FAIL — $1" >&2; }

# honest-gates D37: never `printf … | grep -q`.
has()      { grep -q   -- "$2" <<<"$1"; }
has_line() { grep -qx  -- "$2" <<<"$1"; }
has_ere()  { grep -qE  -- "$2" <<<"$1"; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/registration-sample-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ── fixture construction ─────────────────────────────────────────────────────
# Shas are synthetic 40-char oids; --fixture-dir never touches git, which is the
# point — the harness must run on a machine with no network and no such commits.
H1='1111111111111111111111111111111111111111'   # NEITHER, both success   -> QUALIFIES
H2='2222222222222222222222222222222222222222'   # NEITHER, both success   -> QUALIFIES (PLANT A target)
H3='3333333333333333333333333333333333333333'   # BOTH,    both success   -> QUALIFIES
H4='4444444444444444444444444444444444444444'   # NEITHER, both success   -> QUALIFIES
H5='5555555555555555555555555555555555555555'   # NEITHER, Cloud NO-RUN   -> no
H6='6666666666666666666666666666666666666666'   # NEITHER, Cloud CADENCE  -> no

check_run_json() { # <name> <conclusion> <status> <started_at>
  printf '{"name":"%s","conclusion":%s,"status":"%s","started_at":"%s"}' \
    "$1" "$(if [ "$2" = 'null' ]; then printf 'null'; else printf '"%s"' "$2"; fi)" "$3" "$4"
}

write_checkruns() { # <dir> <sha> <json-rows...>
  local dir="$1" sha="$2"; shift 2
  local body="" row
  for row in "$@"; do
    [ -z "$body" ] || body="$body,"
    body="$body$row"
  done
  printf '{"total_count":%d,"check_runs":[%s]}\n' "$#" "$body" >"$dir/checkruns-$sha.json"
}

run_json() { # <path> <status> <conclusion> <started_at>
  printf '{"path":"%s","status":"%s","conclusion":%s,"run_started_at":"%s"}' \
    "$1" "$2" "$(if [ "$3" = 'null' ]; then printf 'null'; else printf '"%s"' "$3"; fi)" "$4"
}

write_runs() { # <dir> <sha> <json-rows...>
  local dir="$1" sha="$2"; shift 2
  local body="" row
  for row in "$@"; do
    [ -z "$body" ] || body="$body,"
    body="$body$row"
  done
  printf '{"total_count":%d,"workflow_runs":[%s]}\n' "$#" "$body" >"$dir/runs-$sha.json"
}

CONSOLE_WF='.github/workflows/console-harness.yml'
CLOUD_WF='.github/workflows/cloud.yml'

make_control() {
  local d="$1"
  mkdir -p "$d"
  printf '%s\n' "$H1" "$H2" "$H3" "$H4" "$H5" "$H6" >"$d/heads.txt"

  # NEITHER-shape diffs: real repo paths that are in neither declared set.
  printf 'docs/INDEX.md\n'                 >"$d/changed-$H1.txt"
  printf 'README.md\napi/lib/x.ex\n'       >"$d/changed-$H2.txt"
  # BOTH-shape: cloud/priv/static/** is in the CONSOLE set, cloud/** in the CLOUD set.
  printf 'cloud/priv/static/app.css\n'     >"$d/changed-$H3.txt"
  printf 'internal/tui/x.go\n'             >"$d/changed-$H4.txt"
  printf 'mix.exs\n'                       >"$d/changed-$H5.txt"
  printf 'web/app/page.tsx\n'              >"$d/changed-$H6.txt"

  local sha
  for sha in "$H1" "$H2" "$H3" "$H4"; do
    write_checkruns "$d" "$sha" \
      "$(check_run_json 'Console gate' success completed '2026-07-30T10:00:00Z')" \
      "$(check_run_json 'Cloud gate'   success completed '2026-07-30T10:00:00Z')" \
      "$(check_run_json 'Elixir gate'  success completed '2026-07-30T10:00:00Z')"
    write_runs "$d" "$sha" \
      "$(run_json "$CONSOLE_WF" completed success '2026-07-30T09:50:00Z')" \
      "$(run_json "$CLOUD_WF"   completed success '2026-07-30T09:50:00Z')"
  done

  # H5 — ABSENCE CAUSE 1: no cloud run exists at all (the workflow never fired).
  write_checkruns "$d" "$H5" \
    "$(check_run_json 'Console gate' success completed '2026-07-30T10:00:00Z')"
  write_runs "$d" "$H5" \
    "$(run_json "$CONSOLE_WF" completed success '2026-07-30T09:50:00Z')"

  # H6 — ABSENCE CAUSE 2: the cloud run exists and was CANCELLED. A run evicted
  # while pending emits no check run at all, so `if: always()` cannot rescue it.
  # Its check-run feed is EMPTY on purpose (measured shape: total_count=0), which
  # is also the case that would abort a die-on-empty primitive.
  write_checkruns "$d" "$H6"
  write_runs "$d" "$H6" \
    "$(run_json "$CONSOLE_WF" completed cancelled '2026-07-30T09:50:00Z')" \
    "$(run_json "$CLOUD_WF"   completed cancelled '2026-07-30T09:50:00Z')"
}

run_sampler() { # <fixture-dir> -> sets OUT / RC
  set +e
  OUT="$(bash "$SCRIPT" --fixture-dir "$1" 2>&1)"
  RC=$?
  set -e
}

# ── DERIVED expectations, never hard-coded counts ────────────────────────────
# The fixtures name real repo paths, and whether a given path is CONSOLE-, CLOUD-,
# BOTH- or NEITHER-shape is decided by the two ratchets, which MOVE. #11082
# (0e94b99fe) widened CLOUD_PATHS with `internal/**`; the control fixture's
# `internal/tui/x.go` head silently stopped being NEITHER-shape and three
# hard-coded `of which NEITHER` expectations went stale at once — the harness
# red-flagged a sampler that was reporting the truth. So the harness asks the
# SAME ratchets the sampler asks, and asserts the sampler AGREES with them,
# rather than pinning a number that a future widening (or narrowing) inverts.
#
# This is not a tautology: the derivation below is an independent walk over the
# fixture's own head list, so an arithmetic, exclusion or aggregation bug in the
# sampler (which is what these assertions exist to catch) still reds. Only a
# wrong RATCHET would fool both — and this file's doctrine is already that path
# classification is delegated, never mocked (see the header).
shape_of() { # <fixture-dir> <sha> -> EMPTY | NEITHER | CONSOLE | CLOUD | BOTH
  local paths console cloud
  paths="$(cat "$1/changed-$2.txt")"
  if [ -z "$paths" ]; then printf 'EMPTY'; return 0; fi
  # HERE-STRING, never `printf … | script`: `--match` ends in `grep -Eq`, and a
  # pipe writer taking SIGPIPE would promote 141 over the answer (D37).
  console="$(bash "$HERE/console-path-escape-check.sh" --match console <<<"$paths")"
  cloud="$(bash "$HERE/cloud-path-escape-check.sh"     --match cloud   <<<"$paths")"
  case "$console:$cloud" in
    false:false) printf 'NEITHER' ;;
    true:true)   printf 'BOTH'    ;;
    true:false)  printf 'CONSOLE' ;;
    *)           printf 'CLOUD'   ;;
  esac
}

neither_among() { # <fixture-dir> <sha...> -> how many are NEITHER-shape
  local d="$1" n=0 s
  shift
  for s in "$@"; do
    if [ "$(shape_of "$d" "$s")" = 'NEITHER' ]; then n=$((n + 1)); fi
  done
  printf '%d' "$n"
}

neither_line() { # <count> -> the summary line the sampler must print
  printf '  of which NEITHER    %s   (need >= 1)' "$1"
}

echo "registration-sample.test.sh"
echo

# ── CONTROL ──────────────────────────────────────────────────────────────────
echo "control — unmutated fixtures clear the bar"
CONTROL="$TMPROOT/control"
make_control "$CONTROL"
run_sampler "$CONTROL"

if [ "$RC" -eq 0 ]; then ok "control exits 0"; else no "control exited $RC, expected 0"; echo "$OUT" >&2; fi
if has "$OUT" 'the bar is cleared'; then ok "control prints the cleared verdict"; else no "control never printed the cleared verdict"; fi
if has_line "$OUT" 'qualifying            4   (need >= 2)'; then ok "control counts 4 qualifying heads"; else no "control qualifying count wrong"; echo "$OUT" >&2; fi
# Qualifying heads in the control are H1..H4; how many of them are NEITHER-shape
# is the ratchets' call, not this file's.
CONTROL_NEITHER="$(neither_among "$CONTROL" "$H1" "$H2" "$H3" "$H4")"
if [ "$CONTROL_NEITHER" -ge 1 ]; then
  ok "the control fixture still carries $CONTROL_NEITHER NEITHER-shape qualifier(s) (derived from the ratchets)"
else
  no "no fixture head is NEITHER-shape any more — both path sets have swallowed the control diffs, so the shape clause is UNEXERCISED. Give one head a path outside CONSOLE_PATHS and CLOUD_PATHS."
fi
if has_line "$OUT" "$(neither_line "$CONTROL_NEITHER")"; then ok "control counts $CONTROL_NEITHER NEITHER-shape qualifiers, agreeing with the ratchets"; else no "control neither-shape count wrong (ratchets say $CONTROL_NEITHER)"; echo "$OUT" >&2; fi
if has_line "$OUT" 'shim defects          0   (need 0)'; then ok "control reports zero shim defects"; else no "control shim-defect count wrong"; fi
# The four-cause classifier must be visible in the GREEN case, not only the reds.
if has "$OUT" 'ABSENT:NO-RUN'; then ok "control resolves one absence as NO-RUN"; else no "control never showed NO-RUN"; fi
if has "$OUT" 'ABSENT:CADENCE'; then ok "control resolves another absence as CADENCE"; else no "control never showed CADENCE"; fi
# H6's check-run feed is empty; a die-on-empty primitive would abort right here.
if has "$OUT" "${H6:0:9}"; then ok "an EMPTY check-run feed is a CADENCE row, not an abort"; else no "the empty-feed head never made it into the table"; fi
if has "$OUT" 'BOTH'; then ok "the BOTH-shape head classifies through the real --match"; else no "no BOTH-shape head — path classification is not being exercised"; fi
echo

# ── PLANT A — dropped Cloud gate on a CONCLUDED run ──────────────────────────
echo "plant A — a concluded run that published no 'Cloud gate' is a SHIM DEFECT"
PA="$TMPROOT/plant-a"
make_control "$PA"
# H2's cloud run still reads completed/success; only the check run is gone.
write_checkruns "$PA" "$H2" \
  "$(check_run_json 'Console gate' success completed '2026-07-30T10:00:00Z')" \
  "$(check_run_json 'Elixir gate'  success completed '2026-07-30T10:00:00Z')"
run_sampler "$PA"

if [ "$RC" -ne 0 ]; then ok "plant A reds (exit $RC)"; else no "plant A exited 0 — a shim defect passed"; echo "$OUT" >&2; fi
if has "$OUT" 'ABSENT:SHIM-DEFECT'; then ok "plant A names the cause SHIM-DEFECT"; else no "plant A did not classify the absence as a shim defect"; echo "$OUT" >&2; fi
if has_line "$OUT" 'shim defects          1   (need 0)'; then ok "plant A counts exactly one shim defect"; else no "plant A shim-defect count wrong"; echo "$OUT" >&2; fi
# THE POINT: the count bar is still satisfied. A count-only precondition passes here.
if has_line "$OUT" 'qualifying            3   (need >= 2)'; then ok "plant A still satisfies the COUNT bar (3 >= 2)"; else no "plant A qualifying count wrong — the mutation moved more than the shim"; echo "$OUT" >&2; fi
# H2 is the shim-defect head, so the qualifiers left are H1, H3, H4.
PA_NEITHER="$(neither_among "$PA" "$H1" "$H3" "$H4")"
if [ "$PA_NEITHER" -ge 1 ]; then ok "plant A's mutation leaves $PA_NEITHER NEITHER-shape qualifier(s) — the shape bar is still satisfiable"; else no "plant A now has no NEITHER-shape qualifier, so the shape clause would ALSO trip and the mutation is no longer isolated"; fi
if has_line "$OUT" "$(neither_line "$PA_NEITHER")"; then ok "plant A still satisfies the SHAPE bar ($PA_NEITHER >= 1)"; else no "plant A neither-shape count wrong (ratchets say $PA_NEITHER)"; echo "$OUT" >&2; fi
if has "$OUT" 'REFUSE: 1 shim defect'; then ok "plant A refuses ON the shim defect, with the count bar green"; else no "plant A refusal did not cite the shim defect"; fi
if has "$OUT" 'REFUSE: only'; then no "plant A also tripped the count clause — the mutation is not isolated"; else ok "plant A trips ONLY the shim-defect clause"; fi
echo

# ── PLANT B — no NEITHER-shape qualifier left ────────────────────────────────
echo "plant B — four qualifying heads, none of which touches NEITHER path set"
PB="$TMPROOT/plant-b"
make_control "$PB"
# Reshape every NEITHER-shape qualifier into a CLOUD-shape one. Counts are
# untouched; only the shape moves.
printf 'cloud/lib/a.ex\n' >"$PB/changed-$H1.txt"
printf 'cloud/lib/b.ex\n' >"$PB/changed-$H2.txt"
printf 'cloud/lib/c.ex\n' >"$PB/changed-$H4.txt"
run_sampler "$PB"

if [ "$RC" -ne 0 ]; then ok "plant B reds (exit $RC)"; else no "plant B exited 0 — a shape-blind sample passed"; echo "$OUT" >&2; fi
if has_line "$OUT" 'qualifying            4   (need >= 2)'; then ok "plant B still satisfies the COUNT bar (4 >= 2)"; else no "plant B qualifying count wrong"; echo "$OUT" >&2; fi
# The mutation's whole claim is that NO qualifier is NEITHER-shape any more; ask
# the ratchets whether it still does what it says before believing the sampler.
PB_NEITHER="$(neither_among "$PB" "$H1" "$H2" "$H3" "$H4")"
if [ "$PB_NEITHER" -eq 0 ]; then ok "plant B's reshape genuinely removes every NEITHER-shape qualifier (derived from the ratchets)"; else no "plant B's reshape has decayed — the ratchets still score $PB_NEITHER qualifier(s) NEITHER, so the shape clause is not what reds"; fi
if has_line "$OUT" "$(neither_line "$PB_NEITHER")"; then ok "plant B has $PB_NEITHER NEITHER-shape qualifiers"; else no "plant B neither-shape count wrong (ratchets say $PB_NEITHER)"; echo "$OUT" >&2; fi
if has "$OUT" 'touch NEITHER path set, need 1'; then ok "plant B refuses ON the shape clause"; else no "plant B refusal did not cite the shape clause"; echo "$OUT" >&2; fi
if has "$OUT" 'REFUSE: only'; then no "plant B also tripped the count clause — not isolated"; else ok "plant B does not trip the count clause"; fi
if has_line "$OUT" 'shim defects          0   (need 0)'; then ok "plant B reports no shim defect"; else no "plant B also reported a shim defect — not isolated"; fi
echo

# ── PLANT C — everything in flight ───────────────────────────────────────────
echo "plant C — runs not yet completed leave the head UNSETTLED, not ABSENT"
PC="$TMPROOT/plant-c"
make_control "$PC"
for sha in "$H1" "$H2" "$H3" "$H4"; do
  # The aggregator check-run has not been published yet AND its run is moving:
  # this is the measured feed-lag shape, and calling it a defect would refuse a
  # legal registration.
  write_checkruns "$PC" "$sha" \
    "$(check_run_json 'Elixir gate' null in_progress '2026-07-30T10:00:00Z')"
  write_runs "$PC" "$sha" \
    "$(run_json "$CONSOLE_WF" in_progress null '2026-07-30T09:50:00Z')" \
    "$(run_json "$CLOUD_WF"   in_progress null '2026-07-30T09:50:00Z')"
done
run_sampler "$PC"

if [ "$RC" -ne 0 ]; then ok "plant C reds (exit $RC)"; else no "plant C exited 0 — an unsettled window was treated as proof"; echo "$OUT" >&2; fi
if has "$OUT" 'ABSENT:IN-FLIGHT'; then ok "plant C names the cause IN-FLIGHT"; else no "plant C did not classify the absence as in-flight"; echo "$OUT" >&2; fi
if has "$OUT" 'UNSETTLED'; then ok "plant C marks the heads UNSETTLED"; else no "plant C never printed an UNSETTLED verdict"; echo "$OUT" >&2; fi
if has_line "$OUT" 'unsettled (excluded)  4'; then ok "plant C excludes all four heads from the sample"; else no "plant C unsettled count wrong"; echo "$OUT" >&2; fi
if has_line "$OUT" 'qualifying            0   (need >= 2)'; then ok "plant C leaves zero qualifying heads"; else no "plant C qualifying count wrong"; echo "$OUT" >&2; fi
if has_line "$OUT" 'shim defects          0   (need 0)'; then ok "plant C reports NO shim defect — in-flight is not a bug"; else no "plant C mis-blamed an in-flight run on the shim"; echo "$OUT" >&2; fi
echo

# ── the two structural traps ─────────────────────────────────────────────────
echo "traps — empty diff excluded, and the sampler carries no path glob of its own"
PD="$TMPROOT/empty-diff"
make_control "$PD"
: >"$PD/changed-$H1.txt"          # a revert pair / merge commit: no changed paths
run_sampler "$PD"
if has "$OUT" 'EXCLUDED (empty diff'; then ok "an empty-diff head is EXCLUDED, never scored NEITHER"; else no "empty-diff head was not excluded"; echo "$OUT" >&2; fi
if has_line "$OUT" 'empty-diff (excluded) 1'; then ok "the empty-diff exclusion is counted in the summary"; else no "empty-diff count missing from the summary"; fi
# H1 is the emptied head, so the qualifiers left are H2, H3, H4. If H1 leaked in
# it would score NEITHER and read one HIGHER than the ratchets allow.
PD_NEITHER="$(neither_among "$PD" "$H2" "$H3" "$H4")"
if has_line "$OUT" "$(neither_line "$PD_NEITHER")"; then ok "the excluded head did not inflate the NEITHER count (ratchets say $PD_NEITHER)"; else no "the empty-diff head leaked into the NEITHER count (ratchets say $PD_NEITHER)"; echo "$OUT" >&2; fi

# The sampler must delegate every path decision. A `/**` glob or a `.github/`
# literal in the executable body means it has started to fork the ratchets.
body="$(sed -e '/^#/d' -e 's/[[:space:]]#.*$//' "$SCRIPT")"
if has "$body" '/\*\*'; then no "the sampler carries a '/**' glob — path logic must live in the ratchets"; else ok "the sampler carries no path glob of its own"; fi
if has_ere "$body" 'console-path-escape-check\.sh"? --match console'; then ok "console classification shells out to the ratchet"; else no "console classification does not shell out to the ratchet"; fi
if has_ere "$body" 'cloud-path-escape-check\.sh"? --match cloud'; then ok "cloud classification shells out to the ratchet"; else no "cloud classification does not shell out to the ratchet"; fi
if has "$body" 'quotepath=false'; then ok "the diff producer sets core.quotepath=false"; else no "the diff producer is not quotepath-hardened"; fi
if has "$body" -- '-z --name-only --no-renames'; then ok "the diff producer is NUL-delimited and rename-free"; else no "the diff producer is not -z/--no-renames hardened"; fi
if has "$body" 'rev-parse --verify --quiet "\$head\^{commit}"'; then ok "refs are normalised to a full oid before any runs query"; else no "an abbreviated sha could reach actions/runs?head_sha="; fi

# The shared primitive must NOT inherit the incumbents' die-on-empty.
lib="$HERE/lib/check-runs.sh"
if [ -f "$lib" ]; then ok "scripts/lib/check-runs.sh exists"; else no "scripts/lib/check-runs.sh is missing"; fi
libbody="$(sed -e '/^#/d' "$lib")"
if has "$libbody" 'refusing to generate'; then no "the shared primitive inherited a die-on-empty"; else ok "the shared primitive does not die on an empty feed"; fi
if has "$(sed -e '/^#/d' "$SCRIPT")" 'scripts/lib/check-runs.sh'; then ok "the sampler sources the shared primitive"; else no "the sampler does not source scripts/lib/check-runs.sh"; fi
echo

# The primitive must OWN its exit status. As a bare pipeline it returned
# SORT's rc, so a payload that broke jq mid-stream (e.g. {"check_runs":[1,…]})
# read as rc 0 with EMPTY rows — the silent empty set its header forbids — for
# any caller that did not set pipefail. These cases run in a FRESH bash with
# DEFAULT options, so a pass can never be borrowed from this harness's own
# `set -o pipefail`.
LIBFIX="$TMPROOT/libfix"; mkdir -p "$LIBFIX"
printf '%s\n' '{"check_runs":[1,{"name":"Elixir gate","conclusion":"success","status":"completed","started_at":"2026-08-23T00:00:00Z"}]}' > "$LIBFIX/checkruns-aaa.json"
printf '%s\n' '{"check_runs":[null]}' > "$LIBFIX/checkruns-bbb.json"
printf '%s\n' '{"check_runs":[{"conclusion":"success","status":"completed"}]}' > "$LIBFIX/checkruns-ccc.json"
printf '%s\n' '{"check_runs":[]}' > "$LIBFIX/checkruns-ddd.json"
run_rows() { # <sha> — fresh bash, default options, stdout only
  bash -c '. "$1" && check_runs_rows repo "$2" "$3"' _ "$lib" "$1" "$LIBFIX"
}
set +e
out="$(run_rows aaa 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then ok "a non-object element returns 2 with nothing on stdout under DEFAULT shell options"; else no "non-object element: rc=$rc out='$out' — the silent empty set is back"; fi
set +e
out="$(run_rows bbb 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then ok "a null element returns 2, never a phantom row"; else no "null element: rc=$rc out='$out'"; fi
set +e
out="$(run_rows ccc 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then ok "a nameless run returns 2, never an empty-name row"; else no "nameless run: rc=$rc out='$out'"; fi
set +e
out="$(run_rows ddd 2>/dev/null)"; rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "an EMPTY feed still returns 0 rows and exit 0 — the caller rules (the deliberate divergence holds)"; else no "empty feed: rc=$rc out='$out' — the deliberate divergence broke"; fi
echo

# ── usage guards ─────────────────────────────────────────────────────────────
echo "usage — the instrument fails loudly rather than measuring nothing"
set +e
out="$(bash "$SCRIPT" --fixture-dir "$TMPROOT/does-not-exist" 2>&1)"; rc=$?
set -e
if [ "$rc" -eq 2 ]; then ok "a missing fixture directory exits 2 (cannot measure), not 1"; else no "missing fixture dir exited $rc, expected 2"; fi
set +e
out="$(bash "$SCRIPT" --limit 0 2>&1)"; rc=$?
set -e
if [ "$rc" -eq 2 ]; then ok "--limit 0 exits 2"; else no "--limit 0 exited $rc, expected 2"; fi
set +e
out="$(bash "$SCRIPT" --nonsense 2>&1)"; rc=$?
set -e
if [ "$rc" -eq 2 ]; then ok "an unknown argument exits 2"; else no "unknown argument exited $rc, expected 2"; fi
echo

echo "----"
echo "pass $pass   fail $fail"
[ "$fail" -eq 0 ] || exit 1
