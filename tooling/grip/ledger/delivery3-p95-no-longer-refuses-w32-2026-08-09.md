# delivery/3 no longer refuses p95 — its moduledoc's "REFUSES AT EVERY WIDTH" is stale (wave 32, 2026-08-09)

Re-derivation recipes for the wave-32 v4 verification. Every command below was run as written.

## 1. The claim under test, on origin/main

```
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '1707,1710p'
```

prints `ON TODAY'S CORPUS p95 REFUSES AT EVERY WIDTH. That is the true answer, not a / broken feature: 40%+ of rows in any window are still waiting…`

Note the PATH: `cloud/lib/barkpark_cloud/deploy_ledger.ex`, **not** `.../sites/deploy_ledger.ex`.
`delivery/3` is at line 1758 as briefed.

## 2. delivery/3's own output on the live corpus (control plane rpc)

```
scp -i ~/.ssh/barkpark_indx v4_widths.exs root@178.105.92.191:/tmp/v4_widths.exs
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker cp /tmp/v4_widths.exs cloud-control_plane_green-1:/tmp/v4_widths.exs && \
   docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc "Code.eval_file(\"/tmp/v4_widths.exs\")"'
```

`v4_widths.exs`:

```elixir
alias BarkparkCloud.DeployLedger
as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)
for h <- [1, 3, 6, 12, 24, 72, 168, 336] do
  from = DateTime.add(as_of, -h * 3600, :second)
  d = DeployLedger.delivery(from, as_of, as_of: as_of)
  IO.puts("width=#{h}h sample=#{d.sample} censored=#{d.censored.count} cf=#{d.p95.censored_fraction} unmetered=#{d.unmetered} p50=#{inspect(d.p50.seconds)}/#{d.p50.refused} p95=#{inspect(d.p95.seconds)}/refused=#{d.p95.refused} reason=#{inspect(d.p95.reason)}")
end
```

Result 2026-08-09 ~18:0xZ: p95 PRINTS at 6h/12h/24h/72h/168h/336h; refuses at 1h/3h on
`min_sample` alone. censored_fraction 0.0004–0.0378 — never the 40% the doc assumes.

## 3. Raw SQL basis (same numbers, no Elixir)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"' < v4_delivery_basis.sql
```

`v4_delivery_basis.sql` groups production `deployments` by 24h/72h/7d and counts rows,
`status='live' AND became_live_at IS NULL` (unmetered), and rows with no live mark at/after them
(censored upper bound). It reproduces sample 786/4031/8382, unmetered 0, censored 11.

## 4. On the wire, through the shipped Go reader

```
git worktree add --detach <scratch>/w32v4 origin/main
cd <scratch>/w32v4 && CC=/usr/bin/clang go build -o <scratch>/bp32 ./cmd/barkpark
<scratch>/bp32 cloud deployments --days 1
```

(The repo's own `bp` on PATH is 799 commits behind origin/main and has no `cloud deployments` verb.)

## 5. The test suite

```
cd <scratch>/w32v4/cloud && CC=clang MIX_ENV=test mix deps.get && mix compile
CC=clang MIX_ENV=test mix test test/barkpark_cloud/deploy_ledger_test.exs --only delivery   # 0 tests — NO :delivery tag exists
CC=clang MIX_ENV=test mix test test/barkpark_cloud/deploy_ledger_test.exs:2785 \
                               test/barkpark_cloud/deploy_ledger_delivery_scope_test.exs    # 19 tests, 0 failures
```

The `--only delivery` form is VACUOUS — the describe block at :2785 carries no tag.
