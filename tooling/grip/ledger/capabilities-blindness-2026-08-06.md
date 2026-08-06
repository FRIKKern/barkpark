# capabilities-blindness — re-derivation recipes (2026-08-06, wave 4 verify)

Question asked: *is `AssignDefaultScope`'s DB read what makes `bp` go blind exactly when the box is worst?*
Verdict: **mechanism confirmed, leverage refuted.** It is a real live crash frame and the *only* DB
dependency of an anonymous `/v1/capabilities` read — but it is 2.85x smaller than `OptionalToken`,
which runs *before* it and which every real `bp` call hits (bp always sends a Bearer token).

Measured at 2026-08-06 ~11:50–11:58Z on guerrilla (157.180.90.121), load1 6.14→6.37, swap 975/2047 MB.

## R1 — the plug sits in `:api`, in front of `/v1/capabilities`

    git show origin/main:api/lib/barkpark_web/router.ex | grep -n 'AssignDefaultScope' | head -3
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '30,47p'
    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '1594,1601p'

`pipeline :api` … `plug(BarkparkWeb.Plugs.AssignDefaultScope)` at :43; the capabilities scope
`pipe_through(:api)` + `get("/capabilities", CapabilitiesController, :index)` at :1600.

## R2 — the plug costs THREE uncached round-trips, not one

    git show origin/main:api/lib/barkpark/tenancy.ex | sed -n '275,287p'

`get_default_workspace/0` = bare `Repo.get_by`. `get_default_project/0` calls `get_default_workspace/0`
**again**, then a second `Repo.get_by`. Plug calls both → 3 queries/request, no cache, on a
seeded and effectively immutable row pair.

## R3 — live crash-frame attribution (one frame per crash)

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'L=$(journalctl --since "-1 hour" --no-pager);
      echo "Sent 500: $(echo "$L"|grep -c "Sent 500")";
      echo "assign_default_scope.ex:23: $(echo "$L"|grep -c "assign_default_scope.ex:23")";
      echo "optional_token.ex:18:    $(echo "$L"|grep -c "optional_token.ex:18")";
      echo "require_token.ex:        $(echo "$L"|grep -c "require_token.ex")"'

Result: 827 / 68 / 194 / 37. `OptionalToken` (→ `auth.ex:49 verify_token/1`, `Repo.one`) is the
larger plug-layer consumer and is *upstream* of `AssignDefaultScope`.

## R4 — `/v1/capabilities` really is in the 500 set

    ssh … 'journalctl --since "-1 hour" --no-pager | grep -B4 "Sent 500" \
      | grep -oE "(GET|POST) /[^ ]*" | sort | uniq -c | sort -rn | head'

`45 GET /v1/capabilities` (3rd behind `/v1/admin/site-deploy` 95 and `/v1/tasks` 77).

## R5 — the tenant-metadata tell (which plug a 500 died in, without a stack)

`TenantLogMetadata` runs *after* `AssignDefaultScope`. So a `Sent 500` line **without**
`workspace_id=…` died at or before the scope plug; **with** it, later.

    ssh … 'journalctl --since "-12 min" --no-pager | grep -E "Sent 500|GET /v1/capabilities"'

Observed: `request_id=GMk1XJe3XP2xXkUAARdx [info] GET /v1/capabilities` → `… [info] Sent 500 in
4044ms` with **no** workspace metadata. Anonymous ⇒ `OptionalToken` no-ops ⇒ died in `AssignDefaultScope`.

## R6 — client-observed failure rate (interleaved A/B, avoids load drift)

    TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
    for i in $(seq 1 25); do
      curl -s -o /dev/null -w '%{http_code}/' --max-time 15 -H "Authorization: Bearer $TOK" \
        https://guerrilla.barkpark.cloud/v1/capabilities
      curl -s -o /dev/null -w '%{http_code} ' --max-time 15 \
        https://guerrilla.barkpark.cloud/v1/capabilities
    done

Pooled over 45 pairs: **anon 4/45 (8.9%) 500s, authed 0/45.** Directionally consistent across two
runs but n is small; do NOT rank authed-vs-anon from this. The load-bearing fact is only that a
*static manifest* fails ~9% of the time.

## R7 — the pool is the root, and it is already owned

    ssh … 'grep -n pool_size /opt/barkpark/api/config/runtime.exs; grep -i pool /opt/barkpark/.env'

`runtime.exs:717 pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")`; **no POOL_SIZE in
`.env`** ⇒ 10 connections shared by all HTTP + 29 Oban queue slots + Postgres on the same 3.8 GB box.
130 `EdgeProjector.ProjectorWorker` jobs exceeded 5 s in the hour (one at 37.98 s).
Charter **D28** already records this class and assigns the repair to `jpf-bl-oban-pool-partition`.

## What is NEW versus D28

D28 names `query_pipeline.ex:190` (753) and `verify_token` (333) as the consumers. It does **not**
name `AssignDefaultScope`. The addition: this plug is the *sole* DB dependency of an anonymous
capabilities read, so it alone explains why the one endpoint that needs no database still 500s.
Caching the Default workspace/project pair is cheap and additive — but it is a **second-order** fix
that would not have kept authed `bp` alive through the storm.
