# Re-derivation recipes — gyldendal cross-tenant credential transmission, END TO END (2026-08-09)

Ground: `origin/main` @ `0239dd4ee662dd30c4d8da0c6b9a149638224b1d`. Verifier
`gyldendal-operator`, deploy-reliability wave 26. Read-only; nothing mutated.

## R1 — the transmission is still live, and reproduces on the next crontab tick

```
ssh -o BatchMode=yes -i ~/.ssh/barkpark_indx root@barkpark.cloud \
  'docker exec cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -A -F"|" -c \
   "select barkpark_id,count(*),max(measured_at) from usage_samples where barkpark_id::text like (chr(98)||chr(49)||chr(50)||chr(53)||chr(57)||chr(53)||chr(49)||chr(52))||chr(37) group by 1"'
```

Run twice across a `7,22,37,52` boundary; the count increments and `max` advances.

## R2 — the three rows and who owns the name

```
ssh ... psql ... -c "select id,slug,team_id,url,host,custom_host from barkparks where url like '%gyldendal%' or custom_host like '%gyldendal%'"
dig +short gyldendal.barkpark.cloud
curl -s -o /dev/null -w '%{http_code} via %{remote_ip}\n' https://gyldendal.barkpark.cloud/
```

## R3 — PROVED credentialed egress (the honest floor)

`unavailable_reason: "unreachable"` is emitted ONLY by the three post-request
fall-throughs in `cloud/lib/barkpark_cloud/usage.ex` (:732, :821, :840), i.e.
strictly after `instance_api_headers(admin_token)` was put on the wire. Its
absence before 2026-08-04 11:22 is the key not existing yet, not a request not
being sent.

```
ssh ... psql ... -c "select coalesce(envelope->'meters'->'datasets'->>'unavailable_reason','(none)') reason, count(*), min(measured_at), max(measured_at) from usage_samples where barkpark_id='b1259514-9e7f-4e28-81d9-c7c5ddbc1cbd' group by 1 order by 2 desc"
```

## R4 — every credentialed seam funnels through the `url` column

```
git grep -n 'reveal_admin_token\|instance_admin_token' origin/main -- cloud/lib
git show origin/main:cloud/lib/barkpark_cloud/usage.ex | sed -n '884,890p'
```

Every outbound-with-credential site is guarded by
`%Barkpark{url: url} when is_binary(url) and url != ""` or by
`Usage.instance_base_url/1`, which reads the same column.

## R5 — the release predicate is url-keyed, so the remediation disarms it

```
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '5416,5432p'
```

`provisioning_fqdn_claim/1` selects `where b.url == "https://" <> host`. Null the
url and the `:admin_credential` / `:recent_usage_sample` / `:active_subscription`
legs are never evaluated — the claim answers `:free`.

## R6 — the self-service write path that reaches it

```
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '4040,4095p'
git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex | sed -n '445,448p'
```

`POST /v1/barkparks/:id/domain` is `Auth.require_primary_team_admin` (admin of the
CALLER's own team, not a platform admin), and `platform_custom_host?/1` skips the
DNS ownership proof for any `*.barkpark.cloud` name.

## R7 — the TLS ask gate

```
for d in gyldendal.barkpark.cloud definitely-not-a-name-9z.barkpark.cloud; do
  printf '%s -> ' "$d"; curl -s -o /dev/null -w '%{http_code}\n' "https://api.barkpark.cloud/v1/tls/ask?domain=$d"; done
```

200 for the contested name via `registered_custom_host?/1` (row f5e1392e), 404 for
a control. The 200 is CORRECT for the current holder; it is not the defect.

## R8 — the write-time guard is not on main

```
gh pr view 10944 --json state,mergeStateStatus
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '5330,5335p'
```

`custom_host_taken?/2` calls `provisioning_fqdn_taken?(norm)` (arity 1, no
self-exclusion, exact-string url match). #10944 is OPEN/DIRTY.
