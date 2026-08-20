# raw vs humanized failure_reason — re-derivation recipes (2026-08-05)

Verifier lane `raw-vs-humanized`, deploy-truth wave 1. Every number below is
re-derivable with the command beside it. Control-plane DB = `cloud-db-1` on
`barkpark.cloud`; API = `https://api.barkpark.cloud`.

## R1 — population (26,423 rows: 17,171 failed / 9,252 live)

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select status, count(*) from deployments group by status order by 2 desc;\""
```

## R2 — raw ANSI ESC census (1,351 of 17,171 = 7.9%)

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"select count(*) total, count(*) filter (where position(chr(27) in failure_reason)>0) real_esc from deployments where status='failed' and failure_reason is not null;\""
```

Real 0x1B bytes, not literal `\\x1B` text.

## R3 — run the REAL humanize/1 over the REAL corpus

Export distinct raw reasons + counts:

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -t -c \"select json_agg(row_to_json(t)) from (select failure_reason r, count(*) n from deployments where status='failed' and failure_reason is not null group by 1) t;\"" > raw_reasons.json
```

`failure_copy.ex` has NO alias/import/use, so it compiles standalone — do NOT
use the working tree (it is 434 commits behind and has no `scrub/1` at all):

```
git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex > failure_copy.ex
```

Then `elixir run_humanize.exs` where the script is:

```elixir
Code.require_file("failure_copy.ex")
alias BarkparkCloud.FailureCopy
rows = File.read!("raw_reasons.json") |> :json.decode()
out = Enum.map(rows, fn %{"r" => r, "n" => n} ->
  h = FailureCopy.humanize(r)
  %{n: n, changed: h != r, scrub_changed: FailureCopy.scrub(r) != r,
    esc: String.contains?(r, "\e"), esc_h: String.contains?(to_string(h), "\e")}
end)
```

Expected: rewrites 52 rows / 4 distinct; scrub redacts 0; ESC in raw 1,351;
ESC surviving humanize 1,350.

## R4 — live row-by-row join (892 identical / 27 differ of 919)

Fetch API rows per site (`/v1/sites`, then `/v1/sites/:id/deployments?limit=200`
— the API hard-caps at 200 per site with no cursor, which is why the API-only
census undercounts 17,171 as ~919), collect the failed ids, then:

```
ssh -i ~/.ssh/barkpark_indx root@barkpark.cloud "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -t -c \"select json_agg(json_build_object('id',id,'r',failure_reason)) from deployments where id in (<ids>);\""
```

Diff `db[id]` against `api[id]['failure_reason']`.

## R5 — the scrub path (security gate)

```
git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | grep -n 'def humanize\|def scrub'
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'FailureCopy.humanize\|FailureCopy.scrub'
git show origin/main:cloud/lib/barkpark_cloud/notifications/event_email.ex | grep -n 'FailureCopy'
cd cloud && CC=clang mix test test/barkpark_cloud/failure_copy_test.exs
```

`humanize/1 == classify() |> scrub()`. Every `failure_reason` consumer routes
through `humanize` (router :10303 JSON, :12034 GitHub delivery log) or through
`event_email.cause_then_capture/1` (which calls `scrub/1` directly). There is
NO un-scrubbed door today.

## R6 — raw taxonomy at full scale (classify on raw, not humanized)

Bucket the R3 export by substring on the RAW string:
`HTTP 409` → BOX_BUSY_409 8,830 (51.4%) · `bp-doc-id marker is empty` →
DOC_ID_EMPTY 3,542 (20.6%) · `HTTP 500` → BOX_500 2,882 (16.8%) ·
`graph corpus fetch failed: 403` → FORBIDDEN_403 1,071 (6.2%) · remainder
< 2% each; UNCLASSIFIED 78 (0.5%).
