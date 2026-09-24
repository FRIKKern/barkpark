#!/bin/bash
# SELFTEST for caps-meter.sh's two refusals, and the POSITIVE CONTROL that proves
# they can DISTINGUISH rather than merely fire. Hermetic: it drives the REAL,
# UNMODIFIED meter with a stub `mix` prepended to PATH, so what is under test is
# the meter's own code path, not a reimplementation of it.
#
#   A  broken arm      stub mix dies like argon2_elixir's NIF build does, prints
#                      no ExUnit summary => GUARD 1 must exit 2 naming the arm.
#   B  flat benchmark  stub mix prints a real summary but ignores
#                      CAPS_DERIVE_BENCH_N, so both arms cost the same
#                      => GUARD 2 must exit 3. This is the live tell that caught
#                         the original defect: n=200 and n=5000 came out IDENTICAL.
#   C  POSITIVE CONTROL  stub mix prints a summary AND burns CPU proportional to n
#                      => six rows on stdout and exit 0, in this same proof.
#
# Every arm asserts the PLANT REACHED THE METER (`command -v mix` resolves to the
# stub) before believing its verdict -- a stub that silently failed to shadow the
# real mix would make A and B "pass" for the wrong reason.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
METER="$HERE/caps-meter.sh"
WT="$(cd "$HERE/../../../../.." && pwd)"   # repo root; the meter cds to $WT/api
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/caps-meter-selftest.XXXXXX")"
fails=0

mk_stub() {  # $1 = dir, $2 = body
  mkdir -p "$1"
  { echo '#!/bin/bash'; echo "$2"; } > "$1/mix"
  chmod +x "$1/mix"
}

# A: dies before running a test, exactly as the NIF build failure does.
mk_stub "$ROOT/a" '
echo "==> argon2_elixir" >&2
echo "error: unknown option \"-g\"" >&2
echo "make: *** [all] Error 1" >&2
exit 1'

# B: runs tests, but the benchmark does not scale with n.
mk_stub "$ROOT/b" '
awk "BEGIN{x=0;for(i=0;i<3000000;i++)x+=i;print x}" >/dev/null
echo "Finished in 1.2 seconds"
echo "4 tests, 0 failures"'

# C: runs tests AND scales with CAPS_DERIVE_BENCH_N.
mk_stub "$ROOT/c" '
awk -v n="${CAPS_DERIVE_BENCH_N:-0}" "BEGIN{x=0;m=n*3000;for(i=0;i<m;i++)x+=i;print x}" >/dev/null
echo "Finished in 1.2 seconds"
echo "4 tests, 0 failures"'

run_case() { # $1 label, $2 stubdir, $3 trials -> writes $ROOT/$1.out, sets RC
  local d="$ROOT/$2"
  local resolved
  resolved=$(PATH="$d:$PATH" bash -c 'command -v mix')
  if [ "$resolved" != "$d/mix" ]; then
    echo "PLANT NOT PRESENT for $1: command -v mix = '$resolved', expected '$d/mix'" >&2
    fails=$((fails+1)); RC=-1; return
  fi
  echo "  plant verified: mix -> $resolved"
  PATH="$d:$PATH" bash "$METER" "$WT" 200 5000 "$3" > "$ROOT/$1.out" 2> "$ROOT/$1.err"
  RC=$?
}

echo "== A: broken arm (no ExUnit summary) -- GUARD 1 must REFUSE =="
run_case A a 3
echo "  exit=$RC"
sed -n '1,6p' "$ROOT/A.err"
if [ "$RC" -ne 2 ]; then echo "FAIL A: expected exit 2, got $RC"; fails=$((fails+1));
elif ! grep -q 'REFUSED: trial=1 n=200 produced NO ExUnit summary' "$ROOT/A.err"; then
  echo "FAIL A: refusal did not name the offending arm"; fails=$((fails+1));
elif ! grep -q 'unknown option' "$ROOT/A.err"; then
  echo "FAIL A: the refusal did not surface the arm's OWN error text"; fails=$((fails+1));
elif [ -s "$ROOT/A.out" ]; then
  echo "FAIL A: a timing row was printed anyway:"; cat "$ROOT/A.out"; fails=$((fails+1));
else echo "  PASS A: exit 2, arm named, ZERO timing rows on stdout"; fi

echo "== B: flat benchmark (summary present, n ignored) -- GUARD 2 must REFUSE =="
run_case B b 3
echo "  exit=$RC"
echo "  rows printed: $(grep -c '^trial=' "$ROOT/B.out")"
grep '^A/B:' "$ROOT/B.out"
sed -n '1,2p' "$ROOT/B.err"
if [ "$RC" -ne 3 ]; then echo "FAIL B: expected exit 3, got $RC"; fails=$((fails+1));
elif [ "$(grep -c '^trial=' "$ROOT/B.out")" -ne 6 ]; then
  echo "FAIL B: GUARD 1 should have passed all six arms"; fails=$((fails+1));
elif ! grep -q 'REFUSED: the A/B difference' "$ROOT/B.err"; then
  echo "FAIL B: no A/B refusal"; fails=$((fails+1));
else echo "  PASS B: six arms each ran tests, yet the run REFUSED on a flat A/B"; fi

echo "== C: POSITIVE CONTROL -- healthy run, six rows, exit 0 =="
run_case C c 3
echo "  exit=$RC"
cat "$ROOT/C.out"
if [ "$RC" -ne 0 ]; then echo "FAIL C: expected exit 0, got $RC"; cat "$ROOT/C.err"; fails=$((fails+1));
elif [ "$(grep -c '^trial=' "$ROOT/C.out")" -ne 6 ]; then
  echo "FAIL C: expected six timing rows"; fails=$((fails+1));
else echo "  PASS C: six rows, exit 0 -- the guards DISTINGUISH, they do not refuse everything"; fi

echo
if [ "$fails" -eq 0 ]; then echo "caps-meter selftest: 3/3 PASS (2 refusals + 1 positive control)"; else
  echo "caps-meter selftest: $fails FAILURES (artifacts under $ROOT)"; exit 1; fi
