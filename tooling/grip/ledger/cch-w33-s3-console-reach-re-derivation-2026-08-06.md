# cch-w33 s3 — re-derivation recipes for the console-honesty reach numbers (2026-08-06)

Verifier `s3-reaim-empty-and-midstage-consoles`. Every number below is re-derivable
from these exact commands. Prod control-plane DB, read-only.

## Prod reach (barkpark_cloud_prod, cloud-db-1)

```sh
SSH="ssh -i ~/.ssh/barkpark_indx root@178.105.92.191"
PSQL="docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c"

# A. the three failed-row populations
$SSH "$PSQL \"select count(*) total, count(*) filter (where coalesce(array_length(console,1),0)=0) empty_console, count(*) filter (where coalesce(array_length(console,1),0)>0 and console[array_length(console,1)]->>'status' <> 'failed') nonterminal from deployments where status='failed';\""
# → total 17680 | empty_console 9550 | nonterminal 2875

# B. THE REFUTATION: no failed row lacks a failure_reason
$SSH "$PSQL \"select count(*) from deployments where status='failed' and failure_reason is null;\""
# → 0

# C. reach is NINE sites, not 12k customers
$SSH "$PSQL \"select count(distinct site_id) sites, count(*) rows from deployments where status='failed' and array_length(console,1)>0 and console[array_length(console,1)]->>'status' <> 'failed';\""
# → sites 9 | rows 2881

# D. ring fired twice; chop never fired
$SSH "$PSQL \"select count(*) from deployments where array_length(console,1) >= 300;\""   # → 2
$SSH "$PSQL \"select max(length(e->>'line')) from deployments, unnest(console) e;\""      # → 231  (cap is 2_000)

# E. the non-terminal population is dying, not growing
$SSH "$PSQL \"select date_trunc('day',inserted_at)::date, count(*) from deployments where status='failed' and array_length(console,1)>0 and console[array_length(console,1)]->>'status' <> 'failed' group by 1 order by 1 desc limit 8;\""
# → 08-05:105  08-04:7  08-03:47  08-02:101  08-01:57  07-31:109  07-30:261  07-29:821
```

## Surface render (node vm over the SHIPPED artifact)

`scratchpad/probe.mjs` reuses `cloud/priv/static/__app.test.mjs`'s sandbox preamble
verbatim and grabs `__bpTestHook`. Re-create it by copying lines 26-77 of that file
and calling the hooks. Literal results on origin/main `0792d3347`:

| row shape | deployConsoleHtml | deployDetailHtml | fail panel |
|---|---|---|---|
| failed, `console=[]`, detail==failure_reason | `""` | `""` | renders `failure_reason` via `deployTerminalFailHtml` (app.js:10695) |
| failed, last entry `status:"running"` | `…deploy-console-count">2 lines…` | `""` | renders `failure_reason` |

`deployRailLedgerFromConsole` on the second shape returns
`{"BUILD":{"status":"running",…}}` — but `railDeployment()` selects only
`deployIsActive` rows, so a terminal row NEVER mounts the rail. A guard on the rail
for this population would be vacuous (clause seven).

## Write path

`Sites.Deploy.fail/2` — `cloud/lib/barkpark_cloud/sites/deploy.ex:1147` on
origin/main — writes `status/failure_reason/detail` through
`Registry.transition_deployment_fenced/4` and appends NOTHING to `console`.
Eight call sites (`:636 :645 :658 :661 :858 :870 :883 :1075`). Not the builder
latch, not `StaleDeploymentReaper` (it writes no `failed` transition at all).

```sh
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '1147,1163p'
git show origin/main:cloud/lib/barkpark_cloud/workers/stale_deployment_reaper.ex | grep -n "transition\|failure_reason\|console"
```

## Serializer: no migration needed

`caption_entry/3` and `scrub_entry/2` (router.ex, `cloud/lib/barkpark_cloud/web/router.ex`)
both `Map.put` onto the existing entry, so per-entry `status` and `stage` already
reach the client untouched. A completeness marker is computable CLIENT-SIDE from
`d.status` vs `d.console[last].status` — no migration, no new field, no
`cloud/**` auto-deploy ordering problem.

```sh
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '/defp caption_entry/,+10p'
```

## Collision

Open task `dr-bl-500-caption-lie` (GH #9585, parent `task-fb4fb869490b4213`,
wave_paper `deploy-truth-wave-1-2026-08-05`) already owns the SERVER half of this
exact population — `box_refusal/2` producing a byte-identical caption from both the
start path and every poll beat. Its brief cites `deploy.ex:986`; the function is at
`:1166` on origin/main (anchor drift). cch must not re-file it.

```sh
bp task get dr-bl-500-caption-lie
```
