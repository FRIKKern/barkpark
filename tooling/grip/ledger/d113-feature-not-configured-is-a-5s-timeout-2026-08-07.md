# D113 re-derivation recipe — `feature_not_configured` is a 5,000 ms GenServer timeout, not an env hole

Verified 2026-08-07 against guerrilla (157.180.90.121, `/opt/barkpark` HEAD `8ae30b34b`) and
`origin/main`. Wave 10 verifier assignment `d113-fnc-remeasure`. D113 lives only in the UNTRACKED
charter copy (line 2447); origin/main's charter stops at D105.

## Claim

Every `feature_not_configured` 503 on `POST /v1/admin/site-deploy` is a `GenServer.call/2` default
(5,000 ms) expiring inside `safe_call/2`, which converts the `:exit` to `{:error, :disabled}`.
The flag IS set. The deploy PROCEEDS anyway.

## Recipes

Env flag is set, and the code halves:

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'grep BARKPARK_SITE_DEPLOY_APPLY /opt/barkpark/.env'
    git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '302p;325p;411,425p'
    git show origin/main:api/config/runtime.exs | sed -n '961,966p'

`enabled?/0` (:302) is a pure `Keyword.get` — the fail-closed arm at
`site_deploy_controller.ex:75` returns in ~10 ms and can never be slow. `trigger/1` (:325) is
`safe_call({:trigger, req}, {:error, :disabled})`; `safe_call/2` (:411) calls `GenServer.call(pid, msg)`
with NO timeout. So a slow 503 on that route can only be the timeout arm at
`site_deploy_controller.ex:131`.

Every deploy-route 503 is in the >=5,000 ms band (12 h, both slots):

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'for s in blue green; do
      J=/tmp/j_$s.txt; journalctl -u barkpark-slot@$s --since "-12h" --no-pager > $J
      grep -oE "request_id=[A-Za-z0-9_-]+ .*POST /v1/admin/site-deploy" $J | grep -oE "request_id=[A-Za-z0-9_-]+" | sort -u > /tmp/dp_$s.txt
      grep "Sent 503" $J | grep -oE "request_id=[A-Za-z0-9_-]+" | sort -u > /tmp/f503_$s.txt
      comm -12 /tmp/dp_$s.txt /tmp/f503_$s.txt | wc -l; done'

TRAP: banding those durations with `grep -oE "[0-9]+"` yields TWO numbers per line — the literal
`503` and the ms value. Band on `Sent 503 in ([0-9]+)ms` only.

The deploy proceeds anyway (build unit starts within [-1 s, +12 s] of the refused POST), WITH its
negative control — 504 `Started bp-site-build-*` lines over the same 11 h window give a 13.1%
coincidence floor, so 97.6% is signal:

    # match slow-503 POST epochs against /tmp/starttimes.txt; then re-run the same
    # matcher on 84 RANDOM epochs drawn from [first,last] start time.

Hourly co-movement with box distress (this is what makes it BOX-caused, not config-caused):

    grep -E "Sent 503 in (5|6|7)[0-9]{3}ms" /tmp/j_green.txt | awk '{print $1" "$2" "substr($3,1,2)}' | uniq -c
    grep "DBConnection.ConnectionError" /tmp/j_green.txt | awk '{print substr($3,1,2)}' | uniq -c

## Results (2026-08-07, 12 h window)

| | blue | green |
|---|---|---|
| `POST /v1/admin/site-deploy` | 827 | 670 |
| of those, answered 503 | 2 | 84 |
| of those 503s, >= 5,000 ms | 2 (100%) | 84 (100%) |
| build unit started anyway | 2 | 82 |

Coincidence floor for the build-start matcher: 11/84 (13.1%). Observed 84/86 (97.7%).

Hourly, green: slow-503 5/11/45/21/0/0/0/2 against DBConnection errors
356/686/1391/664/55/100/1/88 (hours 16,17,18,19,20,22,00,03 UTC). Every hour with zero DB
distress has zero slow 503s. An env hole would be flat in time; this is not.

## The structural half nobody had

`bounded_cmd/3` (:2557) bounds `systemd-run` at `ctl_cmd_timeout_ms()` = **15,000 ms**
(`@default_ctl_cmd_timeout_ms`, :184) and is called from inside `handle_call({:trigger, …})`
(:440 → `start_run` → :1131). The callee's own budget is THREE TIMES the caller's implicit 5,000 ms.
The 503 is therefore reachable deterministically, not only under load — and because the timeout
never cancels the server-side work, the build launches regardless. That is the same mechanism the
82/84 measurement shows.

No test on origin/main pins the caller's 5,000 ms budget.

## Filing note

`dr-w8-s2-runner-timeout-stops-blaming-the-flag` already carries the remedy.
`dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures` carries the DISPROVEN env-hole premise
and should not be built as written.
