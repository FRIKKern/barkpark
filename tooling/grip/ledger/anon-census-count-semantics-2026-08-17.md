<!-- doc-tier: cold | canonical-for: anon-census-count-semantics-recipes | budget: 4000tok -->

# Anonymous task+paper census, count semantics, and the author-email field — re-derivation recipes (2026-08-17)

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Written by verifier `v-census-live-reconfirm` for the api-read-path-security-sweep
wave 2 ruling packet. Live-network recipes, so they cannot go through
`node tooling/grip/ledger.mjs write` (host bound + `python3 -c` not allowlisted) —
prose row file, same precedent as `muscle1-public-content-2026-07-28.md`.

**All recipes are READS. None writes anything, anywhere. No document ids are
recorded here — counts only (gyldendal is a customer host).**

## Per-host anonymous census (observed 2026-08-17T08:37Z, re-run stable twice)

```bash
for h in http://89.167.28.206 https://guerrilla.barkpark.cloud \
         https://muscle-1.barkpark.cloud https://gyldendal.barkpark.cloud; do
  for t in task paper; do
    echo -n "$h $t "
    curl -s -m 40 "$h/v1/data/query/production/$t?count=true" \
      | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print("total",r.get("total"),"count",r.get("count"))'
  done
done
```

| host | task total | paper total |
|---|---|---|
| primary 89.167.28.206 | 0 | 15 |
| guerrilla | 6212 | 776 |
| muscle-1 | 3139 | 551 |
| gyldendal (customer) | 13 | 51 |

Widen to the full anon type surface by swapping the inner list for
`task paper tag command metric post page project category author`; a type absent
from the dataset answers `404 not_found`, so the loop self-terminates the census.
Observed: primary = paper/post/page/project/category/author (task+tag+command
present but EMPTY, 200 with total 0 — not 404); guerrilla + muscle-1 =
task/paper/tag/command/metric; gyldendal = task/paper/post/page/project/category/author.

## Count semantics — `total` is the total, `count` is the PAGE

```bash
for L in 1 100 1000 1001 5000; do
  echo -n "limit=$L "
  curl -s -m 60 "https://guerrilla.barkpark.cloud/v1/data/query/production/task?count=true&limit=$L" \
    | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print("total",r.get("total"),"count",r.get("count"),"docs",len(r["documents"]))'
done
```

`total` stays 6212 at every limit. `count` equals the rows on the page. `limit`
is clamped to 1000 (`api/lib/barkpark_web/controllers/query_controller.ex:29`),
so 1001 and 5000 both return 1000. Without `?count=true` there is **no `total`
key at all** — response keys are `count, documents, limit, offset, perspective`
(`maybe_put_total/7`, query_controller.ex:692, is opt-in because it is a second
COUNT query). A consumer that reads `result.count` believing it is the total
silently gets the page size.

## The truncation proof for reland-check (no flip required)

```bash
curl -sS -m 40 "https://guerrilla.barkpark.cloud/v1/data/query/production/task?perspective=published&limit=1000&count=true" \
  | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print("total",r.get("total"),"docs",len(r["documents"]),"signal",any(k in r for k in ("truncated","has_more","next_offset")))'
```

`total 6212 docs 1000 signal False` — the URL at
`.github/workflows/reland-check.yml:66` is byte-identical minus `count=true`, so
CI reads 1000 of 6212 published tasks (16%) with nothing in the payload saying it
was cut. This is a live silent false-green **today**, independent of any
`schema.visibility` flip.

## Anonymous payload weight (the stay-public path's motivation)

```bash
curl -s -m 90 "https://guerrilla.barkpark.cloud/v1/data/query/production/paper" -o /dev/null -w '%{size_download}\n'
```

14,105,971 bytes for the DEFAULT page of 100 papers (`blocks`, `body`,
`body_html`, `body_html_sv` all present; ~141KB/doc). `?count=true` adds 12 bytes
and still ships the 100 full bodies. Extrapolated full anon paper corpus ≈ 110MB.

## The author email field

```bash
curl -s -m 30 'http://89.167.28.206/v1/data/query/production/author?count=true' \
  | python3 -c 'import json,sys;r=json.load(sys.stdin)["result"];print("total",r.get("total"));print(sorted(r["documents"][0].keys()));print(sorted({(d.get("email") or "@").split("@")[-1] for d in r["documents"]}))'
```

`email` is present anonymously on primary (4 authors, 3 non-empty) and on
gyldendal (3 authors, 3 non-empty). Every non-empty address is `@sanity.io` on
BOTH hosts — the Sanity demo/seed dataset, not user-entered or customer PII.
De-escalates the "author PII leak" reading; still a real third-party address in
a public read.

## Staleness / frozen-host probe

```bash
curl -s "https://muscle-1.barkpark.cloud/v1/data/query/production/task?limit=1&order=_updatedAt:desc" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["result"]["documents"][0]["_updatedAt"])'
```

muscle-1 newest task `2026-07-26T14:37:00Z`; its task/paper/tag/command/metric
totals are IDENTICAL to the 2026-07-28 census in
`muscle1-public-content-2026-07-28.md` (3139/551/148/22/6) — muscle-1 has been
frozen for three weeks, which is evidence for the shrink-the-host-set path.
Primary's newest paper is `2026-06-29T18:42:44Z` (its 15 papers are stale).
