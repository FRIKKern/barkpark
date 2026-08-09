# Re-derivation recipes — Arm B live population + ErrorJSON assigns, wave 31 verify (2026-08-09)

Verifier `armb-live-population`. origin/main head at run: `0789ab90a5`.
Hosts: cloud-db-1 `178.105.92.191`, guerrilla `157.180.90.121`, key `~/.ssh/barkpark_indx`. All times UTC.
NOTE (inherited from `doc-id-split-shape-2026-08-07.md`): `docker exec -i … psql -f /tmp/x.sql` resolves the
path INSIDE the container and fails. Pipe on stdin: `docker exec -i cloud-db-1 psql … < /tmp/x.sql`.
NOTE: `timeout(1)` is NOT on this macOS host — `command not found`. Use ssh `-o ConnectTimeout`.

## R1 — the graph-500 deploy-ledger population is 145 rows and 97.2% of it is ONE day

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
      'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod' < armb.sql

with `armb.sql` containing (sanity total FIRST, so a vacuous zero is visible):

    SELECT status, count(*) FROM deployments GROUP BY 1 ORDER BY 2 DESC;
    SELECT date_trunc('hour', inserted_at) hr, stage, count(*), count(DISTINCT site_id) sites
      FROM deployments WHERE status='failed' AND failure_reason LIKE '%graph 500%'
      GROUP BY 1,2 ORDER BY 1;
    SELECT count(*) FROM deployments WHERE failure_reason LIKE '%graph 500%'
      AND inserted_at >= now() - interval '24 hours';

Expect 2026-08-09: all-time partition failed 18643 / live 10942 / deferred 3266. graph-500 = **145 rows,
all `status='failed'`, 135 HEALTH + 10 BUILD**. Hourly: 28 buckets, of which **24 fall inside
2026-08-06 01:00–20:00** (141 rows = 97.2%). After the cascade only FOUR rows exist: 08-07 07:00, 08-08 13:00,
08-08 14:00, 08-09 12:00. Trailing 24 h = **1**. All 10 BUILD rows are one site inside 08-06 09:26–18:24.
Read: the D516-window count (145) and the all-time count are IDENTICAL — the window contains the whole class,
so "145 rows" is a cascade artifact, not a rate. ~1.1 rows/day → n=200 is ~180 days. SELF-REFUTING as a
scoreboard denominator.

## R2 — the live population is on the API WIRE, not in the deploy ledger

    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
      'for s in blue green; do echo -n "$s: "; systemctl is-active barkpark-slot@$s.service; done'
    # → blue active, green inactive (2026-08-09). NEVER assume the slot.

    ssh … root@157.180.90.121 'cd /tmp;
      journalctl -u barkpark-slot@blue.service --since "24 hours ago" --no-pager > g24.log;
      awk "/Sent 500/ {for(i=1;i<=NF;i++) if(\$i ~ /^request_id=/) {sub(/request_id=/,\"\",\$i); print \$i}}" g24.log | sort -u > ids500.txt;
      wc -l < ids500.txt'

Expect **299** distinct 500s in the trailing 24 h, latest 15:50 (db_now 16:08) — still firing. Route
attribution via the request_id join (NEVER `grep -B3`; see `graph-500-attribution-and-rss-2026-08-07.md`):
tasks/prime 77, data/mutate 45, **/v1/graph 42**, bulldocs/papers 33, tasks 28, capabilities 24, tail.

## R3 — the fault families ALREADY partition it exhaustively (this is the decomposition proof)

    ssh … 'cd /tmp; for f in DBConnection.ConnectionError FunctionClauseError Postgrex.Error; do
      echo -n "$f: "; grep -F -f ids500.txt g24.log | grep -F "$f" |
        grep -oE "request_id=[^ ]+" | sort -u | wc -l; done'

Count DISTINCT request_ids, never lines — a line count coincidentally also sums to 299 here and would look
identical while proving nothing. Expect **DBConnection.ConnectionError 265 (88.6%), FunctionClauseError 33
(11.0%), Postgrex.Error 1 (0.3%)**; sum 299, and the residue check
(`comm -23 ids500.txt matched.txt | wc -l`) is **0**. The 33 are all
`no function clause matching in Ecto.Changeset.traverse_errors/2` — a code defect, NOT a pool blip.
This REFUTES wave 5 / task `dr-bl-w5-500-carries-its-own-name`'s "ZERO non-DB 500s, a SINGLE class names the
entire population" as of today: 34/299 = 11.4% are non-DB.

## R4 — what Phoenix actually puts in ErrorJSON's assigns (probe, not reading)

    cd api && MIX_ENV=dev CC=clang mix run --no-start probe.exs

`probe.exs` calls `Phoenix.Endpoint.RenderErrors.__catch__(conn, kind, reason, stack,
[formats: [json: ProbeJSON], log: false])` per shape, wrapped in BOTH `rescue` and `catch` (`render_errors.ex:65` `maybe_raise/3` re-raises every kind
except `NoRouteError`, so an unguarded call aborts the probe), and FLUSHES the mailbox between iterations —
`Plug.Test` posts `{:plug_conn, :sent}` and `__catch__`'s own `receive @already_sent` (`:56-60`) would eat it
and short-circuit the NEXT iteration into `%{conn | state: :sent}` with no render at all. That is a false
negative that looks like a clean pass.

Expect, for every shape, `assign_keys=[:__changed__, :conn, :kind, :reason, :stack, :status]`
(`render_errors.ex:122` builds four; `Phoenix.Controller.render` adds `:conn`). And:

| kind | reason in | `assigns.reason.__struct__` |
|---|---|---|
| `:error` | `%RuntimeError{}` | `RuntimeError` |
| `:error` | `%DBConnection.ConnectionError{}` | `DBConnection.ConnectionError` |
| `:error` | `:badarg` (bare atom) | `ArgumentError` — `Exception.normalize/3` (`render_errors.ex:120`) structifies it |
| `:exit` | `{:timeout, {GenServer, :call, …}}` | **NOT_A_STRUCT** |
| `:throw` | `{:abort, "…"}` | **NOT_A_STRUCT** |
| `:error` | `%Plug.Conn.WrapperError{}` handed DIRECTLY | `Plug.Conn.WrapperError` (the useless name) |

**The WrapperError never reaches `__catch__` in a real Endpoint.** `render_errors.ex:41-43` rescues it and
destructures `%{conn:, kind:, reason:, stack:}` BEFORE calling `__catch__`, so the inner term arrives:
probe step 6b yields `RuntimeError`. No unwrap step is needed — but `kind` MUST be branched on, because
`:exit`/`:throw` carry a bare term and `reason.__struct__` would raise inside the error renderer itself.

## R5 — the current body is byte-identical across all shapes (opacity 100%, leak 0%)

Same probe with `formats: [json: BarkparkWeb.ErrorJSON]`. All three of RuntimeError-with-sentinel,
DBConnection.ConnectionError and the `:exit` tuple emit exactly:

    {"error":{"code":"internal_error","message":"unknown error",
              "hint":"Retry shortly; if it persists, report the request_id to the API operator."}}

The sentinel string never appears. Confirms `error_json.ex:45` `reason_for_template(_) → {:error, :unknown}`
→ `errors.ex:644` `build(_)`. The adjacent `errors.ex:641` `build({:error, reason}) when is_binary(reason)`
already ships a binary as MESSAGE under the SAME `internal_error` code — the legal shape, zero control-plane risk.

## R6 — CAVEAT the DB text cannot settle

`graph 500: unknown error` is `bp-fetch.ts:79-92 pickMessage` rendering `body.error.message`. That string is
produced by `errors.ex:644`, which BOTH `ErrorJSON` and `FallbackController` (`fallback_controller.ex:21-22`,
same `Errors.to_envelope/2`) can reach. **The DB row alone does NOT prove the RenderErrors path.** R3's
journal join is what proves it: the 500s log a raised exception term, and a raise bypasses `action_fallback`.
