#!/bin/bash
# OS METER: /usr/bin/time -l around `LC_ALL=C bash -c`. Reports CPU user+sys of
# the whole child process tree, so every port child and Postgres' client-side
# work is INSIDE the meter -- exactly what :erlang.statistics(:runtime) is blind
# to. NOTE the first draft of this harness used bash's `times` builtin called
# from a command substitution: `times` then reports the SUBSHELL's children, so
# it read 0.0 s for a 30-second run. A meter that reads zero is broken, not fast.
WT="$1"; LO="$2"; HI="$3"; TRIALS="$4"
F=test/barkpark_web/live/studio/pds_w42_caps_derive_op_latency_test.exs
for i in $(seq 1 "$TRIALS"); do
  for N in "$LO" "$HI"; do
    L=$(uptime | sed 's/.*load averages: //' | awk '{print $1}')
    o=$( { /usr/bin/time -l bash -c "cd '$WT/api' && LC_ALL=C MIX_TEST_PARTITION=capsderiver20b CAPS_DERIVE_BENCH_N=$N mix test $F >/dev/null 2>&1"; } 2>&1 )
    echo "trial=$i n=$N load1=$L $(echo "$o" | head -1)"
  done
done
