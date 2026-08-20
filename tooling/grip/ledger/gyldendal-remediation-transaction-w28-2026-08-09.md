# Gyldendal remediation transaction — re-derivation recipes (wave 28, v12)

Every number below is re-derivable. `PSQL` = pipe stdin into cloud-db-1:

```sh
psql() { ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec -i cloud-db-1 sh -c "psql -U \$POSTGRES_USER -d \$POSTGRES_DB"'; }
```

## (a) Buckets WITH the sanity total (D3: a rate prints its population)

```sh
printf "SELECT count(*) AS sanity_total_for_box FROM usage_samples WHERE barkpark_id::text LIKE 'b1259514%%';
SELECT m.value->>'unavailable_reason' r, count(DISTINCT s.id), min(s.inserted_at), max(s.inserted_at)
FROM usage_samples s, lateral jsonb_each(s.envelope->'meters') m
WHERE m.value ? 'unavailable_reason' AND s.barkpark_id::text LIKE 'b1259514%%' GROUP BY 1;" | psql
```

2026-08-09 ~10:25Z: sanity_total **1355**; `unreachable` **458** (2026-08-04 11:22:00 → 2026-08-09 **07:22:01**,
CLOSED), `unauthorized` **11** (2026-08-09 **07:37:01** → **10:07:00**, ADVANCING). Reasoned = 469/1355 = 34.6%;
the other 886 predate the reason key. Never quote 469 as "the transmissions" — it is the floor of *reasoned*
transmissions in the retained window.

## (b) The ordering trap, re-anchored on origin/main (not charter line numbers)

```sh
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '5501,5560p'
```

`provisioning_fqdn_claim/1` is at **5501** (charter D457 cites 5416-5417 — stale). Its `where` is
`b.url == "https://" <> host` (**5507**); `claim_leg/2` (**5533**) orders `:admin_credential` (5535) →
`:recent_usage_sample` (5539) → `:active_subscription` (5543) → `:agent_reporting` → `:active_job` →
`:within_grace`. Live leg inputs for the only matching row:

```sh
printf "SELECT left(b.id::text,8) id,(b.admin_token_encrypted IS NOT NULL) has_admin_token,
EXISTS(SELECT 1 FROM usage_samples us WHERE us.barkpark_id=b.id AND us.measured_at>=now()-interval '24 hours') recent_sample,
EXISTS(SELECT 1 FROM subscriptions s WHERE s.team_id=b.team_id AND s.status IN ('active','past_due')) live_sub,
b.last_seen_at, (b.inserted_at>=now()-interval '7 days') within_grace
FROM barkparks b WHERE b.url='https://gyldendal.barkpark.cloud';" | psql
```
→ `b1259514 | t | t | t | (null) | f`.

Post-null-url population:
```sh
printf "SELECT count(*) FROM barkparks b WHERE b.url='https://gyldendal.barkpark.cloud' AND b.id::text NOT LIKE 'b1259514%%';" | psql
```
→ **0**. Empty list ⇒ `Enum.find_value(:free, …)` returns `:free` and NO leg runs, `:admin_credential` included.
Token-first instead leaves `recent_sample=t` (and `live_sub=t`) ⇒ still `{:held, …}`. **RULED ordering stands:
`admin_token_encrypted` NULL first, `url` NULL second, one BEGIN/COMMIT.**

Refinement: the sole caller is `custom_host_taken?/2` (**5415-5420**), an OR whose
`other_barkpark_custom_host?` arm already refuses the name because **f5e1392e** holds
`custom_host='gyldendal.barkpark.cloud'`. The `:free` answer is therefore not a live name-handover today; the
ordering is required for the credential window, not for the name.

Use `NULL`, never a repoint: `barkparks_url_unique_idx UNIQUE (url) WHERE url IS NOT NULL` (`\d barkparks`).

## (c) The gate to retire, and why criterion 3 cannot be satisfied

```sh
bp task get dr-w25-hg-gyldendal-operator-stops-the-transmission -o json | head -c 1500
```
`status=published`, `rev=80239efd7c09c965d3837f2c7e1f5eef`, id `19faf44d-d321-45ab-ae83-c7e9131e7ecd`.
Criterion 3 = "usage_samples shows no new row for b1259514". The sweep is HOST-keyed
(`checkable_scope/1`, registry.ex **3813-3815**: `not is_nil(b.host) and b.host != ""`) and
`Usage.record_sample/1` (usage.ex **424-432**) inserts unconditionally, so rows keep arriving after a perfect
fix — and `:not_live` is not in `@unavailable_reasons` (usage.ex **161-162**), so the post-fix envelope reads
`"unknown"`. The correct assertion is the corrected draft's: **no new row carrying `unavailable_reason`**.

Unblock for `drafts.dr-w26-hg-gyldendal-operator-packet-corrected`: unpublish or retitle the w25 incumbent
FIRST (dedup wall `@refuse 0.55` / `@min_refuse_shared 3`, `api/lib/barkpark/content/dedup_wall.ex:79,86`).

DO NOT de-register the name from `/v1/tls/ask` — `curl -s -o /dev/null -w '%{http_code}'
'https://barkpark.cloud/v1/tls/ask?domain=gyldendal.barkpark.cloud'` → **200**, owned by f5e1392e's custom_host.
