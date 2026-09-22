#!/bin/bash
# OS METER: /usr/bin/time -l around `LC_ALL=C bash -c`. Reports CPU user+sys of
# the whole child process tree, so every port child and Postgres' client-side
# work is INSIDE the meter -- exactly what :erlang.statistics(:runtime) is blind
# to. NOTE the first draft of this harness used bash's `times` builtin called
# from a command substitution: `times` then reports the SUBSHELL's children, so
# it read 0.0 s for a 30-second run. A meter that reads zero is broken, not fast.
#
# THE SECOND WAY IT READ NOTHING, 2026-09-22 (task-878b408c5abca5e2): the arm was
# `mix test $F >/dev/null 2>&1`. The redirect discards BOTH streams, so a
# `mix test` that dies before running a single test is indistinguishable from one
# that ran the whole benchmark -- and the `time` line exists either way. On this
# box `cc` is a shell alias to Claude Code, so argon2_elixir's NIF build fails and
# the run aborts in under a second. Six clean rows, zero tests, and the n=200 and
# n=5000 arms IDENTICAL when the entire design is that they differ. The header
# above already carried the lesson ("a meter that reads zero is broken, not
# fast") and the code did not enforce it. Now it does, TWICE:
#
#   GUARD 1 (per arm)  the arm's output is captured to a log, not discarded, and
#                      the ExUnit summary line ("N tests, M failures") must be
#                      present with N > 0. Absent or zero => REFUSE, naming the
#                      arm, exit 2. The timing row is NOT printed for that arm.
#   GUARD 2 (per run)  the A/B difference itself. mean CPU(HI) - mean CPU(LO)
#                      must clear a floor. A summary line proves tests ran; it
#                      does not prove the benchmark SCALED with n. Zero
#                      difference REFUSES, exit 3.
#
# THE FLOOR, derived rather than picked: `price!/2` runs `Enum.each(1..@ops, ...)`
# twice and is called at two sites, so one arm costs 4 x n derives and the A/B
# difference is 4 x (HI - LO) derives. The measured band on this code is 96-107
# us CPU per derive (caps-derive-per-op-cost.md, 2026-09-22 quiet-host re-run).
# The floor uses 10 us/derive -- an ORDER OF MAGNITUDE below the low end of that
# band -- so a healthy run clears it ~10x over and cannot false-refuse on host
# load, while a run that measured nothing (difference ~0) can never clear it.
# Override with CAPS_METER_FLOOR_US_PER_DERIVE if the code's cost ever changes.
#
# Run it as: CC=/usr/bin/cc bash caps-meter.sh <worktree> 200 5000 3
# (without CC the argon2_elixir NIF build fails; GUARD 1 now says so out loud
# instead of printing a plausible number.)
set -u
WT="$1"; LO="$2"; HI="$3"; TRIALS="$4"
F=test/barkpark_web/live/studio/pds_w42_caps_derive_op_latency_test.exs
FLOOR_US_PER_DERIVE="${CAPS_METER_FLOOR_US_PER_DERIVE:-10}"
DERIVES_PER_OP_UNIT=4   # price!/2 loops twice, called at two sites

LOGDIR="${CAPS_METER_LOGDIR:-$(mktemp -d "${TMPDIR:-/tmp}/caps-meter.XXXXXX")}"
mkdir -p "$LOGDIR"

sum_lo=0; sum_hi=0; n_lo=0; n_hi=0

for i in $(seq 1 "$TRIALS"); do
  for N in "$LO" "$HI"; do
    arm="trial=$i n=$N"
    log="$LOGDIR/arm-t$i-n$N.log"
    L=$(uptime | sed 's/.*load averages: //' | awk '{print $1}')
    # The redirect STAYS -- it is why the `time` line is readable (c3). It now
    # points at a LOG instead of /dev/null, so the arm's output is available to
    # GUARD 1 without drowning the row. `time`'s own stderr is NOT redirected.
    o=$( { /usr/bin/time -l bash -c "cd '$WT/api' && LC_ALL=C MIX_TEST_PARTITION=capsderiver20b CAPS_DERIVE_BENCH_N=$N mix test $F >'$log' 2>&1"; } 2>&1 )
    t=$(echo "$o" | head -1)

    # GUARD 1 -- the arm must have RUN the benchmark.
    summary=$(grep -Eo '[0-9]+ tests?, [0-9]+ failures?' "$log" | tail -1)
    if [ -z "$summary" ]; then
      echo "REFUSED: $arm produced NO ExUnit summary line -- the arm did not run the benchmark." >&2
      echo "REFUSED: its timing row ($t) would have been a plausible number for zero tests." >&2
      echo "REFUSED: arm output kept at $log ; last 20 lines:" >&2
      tail -20 "$log" >&2
      exit 2
    fi
    ran=${summary%% *}
    if [ "$ran" -eq 0 ]; then
      echo "REFUSED: $arm ran 0 tests ($summary) -- nothing was measured." >&2
      echo "REFUSED: arm output kept at $log" >&2
      exit 2
    fi

    # c3: the timing line survives verbatim, with the witness appended.
    echo "trial=$i n=$N load1=$L $t tests=[$summary]"

    cpu=$(echo "$t" | awk '{u=0;s=0;for(j=1;j<NF;j++){if($(j+1)=="user")u=$j;if($(j+1)=="sys")s=$j}print u+s}')
    if [ "$N" = "$LO" ]; then
      sum_lo=$(awk -v a="$sum_lo" -v b="$cpu" 'BEGIN{print a+b}'); n_lo=$((n_lo+1))
    else
      sum_hi=$(awk -v a="$sum_hi" -v b="$cpu" 'BEGIN{print a+b}'); n_hi=$((n_hi+1))
    fi
  done
done

# GUARD 2 -- the A/B difference must clear a derived floor.
floor=$(awk -v u="$DERIVES_PER_OP_UNIT" -v hi="$HI" -v lo="$LO" -v f="$FLOOR_US_PER_DERIVE" \
        'BEGIN{printf "%.4f", u*(hi-lo)*f/1000000}')
diff=$(awk -v sh="$sum_hi" -v nh="$n_hi" -v sl="$sum_lo" -v nl="$n_lo" \
       'BEGIN{printf "%.4f", (nh?sh/nh:0)-(nl?sl/nl:0)}')
echo "A/B: mean CPU(n=$HI) - mean CPU(n=$LO) = ${diff}s ; floor = ${floor}s ($DERIVES_PER_OP_UNIT x ($HI-$LO) derives x ${FLOOR_US_PER_DERIVE}us)"
if awk -v d="$diff" -v f="$floor" 'BEGIN{exit !(d < f)}'; then
  echo "REFUSED: the A/B difference ${diff}s is below the floor ${floor}s -- the benchmark did not scale with CAPS_DERIVE_BENCH_N," >&2
  echo "REFUSED: so the rows above measure something other than the derives, whatever their summary lines said. Logs: $LOGDIR" >&2
  exit 3
fi
