# beam-metrics-scrape — re-derivation recipes (2026-08-06, wave 4 verify)

Verifier: beam-metrics-scrape. All commands below were run this session against
live guerrilla (157.180.90.121 / guerrilla.barkpark.cloud) and origin/main.

## R1 — the route is deployed and token-gated (401, not 404)

    curl -s -o /dev/null -w '%{http_code}\n' --max-time 12 \
      https://guerrilla.barkpark.cloud/v1/instance/metrics
    # => 401

## R2 — vm_memory_total is PRESENT, NON-ZERO, and LIVE

    TOK=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.config/barkpark/config.json")))["token"])')
    for i in 1 2 3; do
      curl -s --max-time 15 -H "Authorization: Bearer $TOK" \
        https://guerrilla.barkpark.cloud/v1/instance/metrics \
        | grep -E '^vm_(memory_total|total_run_queue)'
      sleep 12
    done
    # => vm_memory_total 1692796.016 / 1684024.168 / 1730828.408  (moves => poller alive)
    # => vm_total_run_queue_lengths_total 12 / 11 / 16

## R3 — the exposition name carries NO unit suffix but the value is KILOBYTES

    git show origin/main:api/lib/barkpark_web/telemetry.ex | sed -n '74,80p'
    # => last_value("vm.memory.total", unit: {:byte, :kilobyte}, ...)
    git show origin/main:api/test/barkpark_web/telemetry_test.exs | sed -n '68,74p'
    # => "# (Core scales by unit but keeps the event-derived name — no _kilobytes suffix.)"

Cross-check against the box (gauge ~1.65 GiB vs beam.smp RSS 1.33 GiB — same order;
as bytes it would be 1.7 MB, absurd):

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'ps -eo pid,rss,comm --sort=-rss | grep beam | head -1; grep -E "^(MemTotal|SwapTotal|SwapFree)" /proc/meminfo'

## R4 — widening the subscription really is ~5 lines (source event already carries the breakdown)

    grep -n "memory" api/deps/telemetry_poller/src/telemetry_poller_builtin.erl
    # => Measurements = erlang:memory(),
    #    telemetry:execute([vm, memory], maps:from_list(Measurements), #{}).
    # i.e. [:vm,:memory] already carries total/processes/binary/ets/code/atom/system.
    git show origin/main:api/lib/barkpark_web/telemetry.ex | sed -n '303,308p'
    # => periodic_measurements/0 is EMPTY; the vm gauges come from telemetry_poller defaults.

## R5 — the --health-token drop-in on guerrilla is an UNMANAGED snowflake (survives self-update)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'systemctl cat barkpark-agent | grep -n "ExecStart\|^# /"; ls -la /etc/systemd/system/barkpark-agent.service.d/'
    # => # /etc/systemd/system/barkpark-agent.service.d/health-token.conf  (Jul 10 02:25)
    #    ExecStart=   (reset)
    #    ExecStart=/bin/sh -c '... --health-token "$(cat /etc/barkpark/agent.health.token)"'

    grep -rn "health-token" --include='*.go' --include='*.sh' --include='*.service' --include='*.yml' \
      deploy internal cmd api cloud
    # => ONLY cmd/barkpark-agent/main.go:48 (the flag definition). Nothing writes it.
    grep -rn "service.d" deploy/ internal/    # => zero hits

instance-deploy.sh:819 installs only the FRAGMENT
(/etc/systemd/system/barkpark-agent.service); it never removes the .d directory,
so the drop-in is NOT clobbered. A bare `systemctl restart barkpark-agent` keeps
--health-token.

## R6 — nothing consumes the metrics route; the far end still renders four series

    grep -rn "instance/metrics" --include='*.go' internal/ cmd/ cloud/   # => zero hits
    bp cloud instance top guerrilla | python3 -c 'import json,sys;print(sorted(json.load(sys.stdin)["series"]))'
    # => ['cpu', 'disk', 'load', 'mem']
