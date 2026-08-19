# vm-timewarp-live — re-derivation recipes (2026-08-19)

Converts the clock-semantics wave's VM premise from documentation-grade to L1
(running system). All commands are literal and re-runnable.

## R1 — api surface (guerrilla 157.180.90.121), OTP default mode

    ssh -i ~/.ssh/barkpark_indx -o StrictHostKeyChecking=no root@157.180.90.121 \
      "export PATH=/root/.asdf/shims:\$PATH; cd /opt/barkpark/api && erl -noshell -eval \
      'io:format(\"mode=~p corr=~p delta=~p otp=~s~n\",[erlang:system_info(time_warp_mode),erlang:system_info(time_correction),os:system_time(millisecond)-erlang:system_time(millisecond),erlang:system_info(otp_release)]),halt().'"

Observed 2026-08-19: `mode=multi_time_warp corr=true delta=0 otp=27`.
NOTE: `erl` is NOT on root's default PATH on this box (asdf shims required) —
the charter's MUST-RUN command as written returns `erl: command not found`.

## R2 — the LIVE api BEAM carries no +C flag (it is `mix phx.server`, not a release)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      "for p in \$(pgrep -f beam.smp | head -1); do tr '\0' ' ' < /proc/\$p/cmdline; echo; \
       tr '\0' '\n' < /proc/\$p/environ | grep -iE 'ERL_FLAGS|ERL_ZFLAGS|ELIXIR_ERL_OPTIONS'; done"

## R3 — cloud control plane (178.105.92.191), probed on the LIVE node via release rpc

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      "docker exec cloud-control_plane_blue-1 sh -lc '/app/bin/barkpark_cloud rpc \
      \"IO.puts(\\\"mode=#{inspect(:erlang.system_info(:time_warp_mode))} corr=#{inspect(:erlang.system_info(:time_correction))} otp=#{:erlang.system_info(:otp_release)}\\\")\"'"

Observed: `mode=:multi_time_warp corr=true otp=27`. The runtime image has no
`erl` on PATH (erts-15.2.7.9 only) — `rpc` is the only probe, and it is the
better one: it reads the process actually serving traffic.

## R4 — flag sensitivity (proves the measured mode is the DEFAULT, not a forced value)

    ssh ... "export PATH=/root/.asdf/shims:\$PATH; for m in no_time_warp single_time_warp multi_time_warp; do \
      erl +C \$m -noshell -eval 'io:format(\"~p~n\",[erlang:system_info(time_warp_mode)]),halt().'; done"

## R5 — VM restart re-derives the offset in EVERY mode (class-D relevant)

    ssh ... "for i in 1 2 3; do erl -noshell -eval 'io:format(\"~p~n\",[erlang:time_offset(millisecond)]),halt().'; done"
    ssh ... "for i in 1 2 3; do erl +C no_time_warp -noshell -eval 'io:format(\"~p~n\",[erlang:time_offset(millisecond)]),halt().'; done"

## R6 — System.os_time bypasses the VM time layer

    ssh ... "erl -noshell -eval 'io:format(\"~p~n\",[erlang:system_info(os_system_time_source)]),halt().'"

Observed: `[{function,clock_gettime},{clock_id,'CLOCK_REALTIME'},...]` — a direct
OS realtime read, no correction/warp layer.

## R7 — host clock discipline (step vs slew)

    ssh ... "systemctl is-active systemd-timesyncd chronyd ntp; timedatectl timesync-status; \
      journalctl -u systemd-timesyncd --no-pager -n 200 | grep -iE 'Initial (clock )?synchron'; \
      journalctl --since '-60d' --no-pager -o cat | grep -iE 'time jump|Time has been changed|clock step|stepped'"

Bound the journal grep (`--since`/`-n`) — an unbounded `journalctl | grep` on
guerrilla exceeds a 120s tool timeout.

## Fence notes for the Paper

* Do NOT recommend `+C no_time_warp`: it freezes the offset, so every class-A
  absolute instant drifts permanently from real wall time after a host
  correction — worse than the bug it patches.
* `System.os_time` (paper_revision_headers.ex:177) is warp-independent (R6), so
  that site's exposure does not depend on the mode answer.
* Register to mirror: cloud/test/barkpark_cloud/sweep_bound_reset_test.exs:38
  "NOT OBSERVED, though: nobody instrumented a production straddle or stepped a
  host clock."
