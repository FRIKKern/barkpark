# Re-derivation recipe — the gyldendal post-fix envelope carries NO reason at all

Wave 29 verifier, `gyldendal-remediation-readiness`, 2026-08-09 ~12:15Z.
origin/main at derivation: `c2de1e51cd029d3f47717eec6c53a81b55970364`.

## The claim

Charter D492 states: ":not_live is not a member of `@unavailable_reasons`
(`usage.ex:161-162`), so the post-fix envelope falls through to `"unknown"` at `:257`."

**That mechanism is wrong.** `:not_live` and `:no_admin_token` never reach
`unavailable_reason/1`. Three `with/else` clauses collapse every error to the
BARE ATOM `:unmetered`, which builds a meter with **no `unavailable_reason` key at all**.

## Re-derive the code path

```sh
git show origin/main:cloud/lib/barkpark_cloud/usage.ex | sed -n '746p;773p;785p'
# 746/773/785:      {:error, _} -> :unmetered

git show origin/main:cloud/lib/barkpark_cloud/usage.ex | sed -n '239p'
# 239: defp instance_meter(:unmetered, source), do: meter(@unmetered, source, nil)
#      ^ no Map.put(:unavailable_reason, ...) — contrast :242 unavailable_meter/2
```

Chain: `instance_admin_token/1` (`:922`) → `{:error, :no_admin_token}` →
`with/else` (`:773`) → `:unmetered` → `instance_meter/2` (`:239`) → reasonless meter.
Identical for `instance_base_url/1` (`:914`) → `{:error, :not_live}`.

## Re-derive the pinning test (already green on main)

```sh
git show origin/main:cloud/test/barkpark_cloud/usage_test.exs | sed -n '337,343p'
# test "a meter that MEASURED, or one deliberately unmetered, carries no reason at all"
#   m = meters(%{webhooks: {:ok, 4}, documents: :unmetered, datasets: nil})
#   refute Map.has_key?(m.documents, :unavailable_reason)
```

## Re-derive the live shapes

```sh
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"select us.envelope->'meters'->'documents' as doc_meter, count(*), max(us.measured_at) from usage_samples us join barkparks b on b.id=us.barkpark_id where b.id::text like 'b1259514%' group by 1 order by 2 desc\""
```

Three shapes, and the reasonless one is REAL, not hypothetical:

| shape | n | last |
|---|---|---|
| no `unavailable_reason` key | 886 | 2026-08-04 11:07:01 |
| `"unreachable"` | 458 | 2026-08-09 07:22:01 |
| `"unauthorized"` | 19 | 2026-08-09 12:07:00 |

The 886 pre-date the reason feature (deployed between 11:07 and 11:22 on 08-04).
**After the remediation the row returns to exactly that byte-shape.**

## Why it matters

1. The readiness question "does the sampler write a row with reason `'unknown'`,
   giving >=3 ticks?" answers **NO — zero ticks, forever.** Any criterion with an
   `'unknown'` denominator MISSES by construction.
2. D492's RULING criterion — "no new row carries a DELIVERY-PROVING reason
   (`unreachable|unauthorized|refused|instance_error`)" — **survives and is
   satisfiable**, more cleanly than D492 knew.
3. But the remediated state is provable only as an **ABSENCE**, byte-identical to
   the pre-08-04 blind era. A silent regression (token or url restored) reports
   NOTHING. Under D479 that is the epic's own sin. The fix wants a POSITIVE
   reading: admit `not_live` / `no_admin_token` to `@unavailable_reasons` and pass
   them through the `else` instead of flattening to `:unmetered`.

## Live-state facts re-derived the same session

```sh
# no live row exercises the token-less path — the fix's path is UNTESTED in prod
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F'|' -c \"select b.slug,(b.admin_token_encrypted is null) tok_null from barkparks b where b.host is not null and b.host<>'' and b.suspended=false\""
# all 8 rows tok_null=f

dig +short gyldendal.barkpark.cloud   # 116.203.98.0 = f5e1392e's box (team Gyldendal)
# b1259514 is team `yo`. Cross-tenant, still 100% misdelivered.

ssh ... -c "select count(*) from barkparks where url='https://gyldendal.barkpark.cloud' and id<>'b1259514-...'"  # 0
# => nulling url first returns :free with no leg evaluated. Token-first order CONFIRMED.
```

`gh pr diff 10944 | awk '/^diff --git/{f=$3} /Ecto.Changeset.change\(url:/{print f}'`
→ only `cloud/test/...`; #10944's registry.ex change is read-path
(`custom_host_taken?/2`) and **cannot undo a NULL url**. It is CONFLICTING/DIRTY.

## Trap recorded

`grep -rn unavailable_reason cloud/test/` in the local checkout returns **0** while
`git grep origin/main` returns **14** — the local working tree is stale (Jul 12).
Grep the ref, not the checkout, before claiming a test is absent.
