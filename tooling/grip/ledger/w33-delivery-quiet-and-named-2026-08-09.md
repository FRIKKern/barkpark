# delivery/3 on a quiet host — the censored cohort is a 5-minute tail, not a permanent one (wave 33, 2026-08-09)

Re-derivation recipes for the `delivery-quiet-and-named` verification. Every command below was run as written
against the LIVE control plane. Host: `barkpark.cloud`, container `cloud-control_plane_green-1`, 2 cores,
`uptime` 20:20 UTC = `load average: 0.38, 0.62, 1.07` (quiet at start; rose to 2.50 under my own rpc runs).

The local checkout is **812 commits behind origin/main** and does not contain
`cloud/lib/barkpark_cloud/deploy_ledger.ex` at all. Read the code with `git show origin/main:<path>`, never
from the worktree.

## 0. The code under test

```
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex > /tmp/dl.ex
sed -n '1921,2010p' /tmp/dl.ex     # delivery/3
sed -n '2043,2093p' /tmp/dl.ex     # observe/3 + delivery_quantile/4
git show origin/main:internal/cli/cloud_deploy_census_cmd.go | sed -n '930,940p'   # the terminal render
git show origin/main:internal/cloudclient/client.go | sed -n '2179,2188p'          # DeployDeliverySite
```

## 1. Widths, boundary pin, and the narrow-window negative control

```
scp -i ~/.ssh/barkpark_indx dw.exs root@barkpark.cloud:/tmp/dw.exs
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'uptime; docker cp /tmp/dw.exs cloud-control_plane_green-1:/tmp/dw.exs && \
   docker exec cloud-control_plane_green-1 /app/bin/barkpark_cloud rpc "Code.eval_file(\"/tmp/dw.exs\")"'
```

`dw.exs` calls `DeployLedger.delivery(from, as_of, as_of: as_of)` at 6h/24h/72h/168h/336h, then with
`from` pinned at `2026-08-05T21:13:50Z`, then at 90m/60m/45m/30m, and finally resolves the censored
`site_id`s against the `sites` table. **`sites` has no `status` column** — the columns are
`id, name, slug, team_id, current_deployment_id, …`; a `select … status …` raises `undefined_column`.
Passing `site_id` strings to `= ANY($1::uuid[])` raises `DBConnection.EncodeError`; interpolate quoted
literals instead.

## 2. The censoring-arm sweep (does p95 ever refuse for CENSORING on real data?)

`dw2.exs` sweeps 180/210/240/270/300/330/360 minutes. The arm fires iff `n >= 200` **and** `c/n > 0.05`,
i.e. `200 <= n < 20c`. With today's `c = 9` that interval is EMPTY — the arm is arithmetically unreachable
at every width on an open (`to = now`) window.

## 3. Where the refusal DOES fire: closed, disjoint day buckets

`dw4.exs` runs 14 disjoint 24h buckets `[as_of-(d+1)*86400, as_of-d*86400)` plus two 72h windows that
end at / start at the taxonomy boundary `2026-08-05T21:13:50Z` (95.17h before `as_of`).

## 4. Healing profile across the boundary

`dw5.exs` runs `[b-24h, b)` and then 6h buckets `[b+6k h, b+6(k+1) h)` for k=0..7.

## 5. Scripts

All four scripts live in the wave-33 verifier scratchpad; each is ~20 lines of
`DeployLedger.delivery/3` calls plus `IO.puts`. Rebuild any of them from the shapes above — the only
non-obvious details are the two SQL traps in §1.
