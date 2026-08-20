# census-403-honesty — re-derivation recipes (2026-08-07 01:02Z)

Verifier row for deploy-reliability wave 8, assignment `census-403-honesty`.
Every line below is a command that re-derives the fact from scratch. No commits here.

## 1. PLATFORM_ADMIN_EMAILS is still UNSET on prod (not inherited)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 \
  'docker exec cloud-control_plane_blue-1 env | grep -c PLATFORM_ADMIN_EMAILS; echo rc=$?'
```

Observed: `0` then `rc=1`. `grep -c` printing 0 with rc=1 is the two-signal form —
count AND exit code agree the var is absent from the serving container's env.

## 2. What the census returns to a REAL user token today

```
curl -s -i -H "Authorization: Bearer $CLOUD_TOKEN" \
  "https://api.barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-06T00:30:00Z&to=2026-08-07T00:30:00Z" | head -30
```

Observed: `HTTP/2 403` +
`{"error":"forbidden","scope":"platform","required":"platform_operator"}`

## 3. Prove the token is a genuine authenticated user (403 is authority, not auth)

```
curl -s -H "Authorization: Bearer $CLOUD_TOKEN" https://api.barkpark.cloud/v1/me
```

Observed: `200`, `"email":"frikk@guerrilla.no"`, `"platform_operator":false`, `"role":"owner"`.

## 4. The anonymous control (fails 401, a DIFFERENT shape)

```
curl -s "https://api.barkpark.cloud/v1/operator/deploy-ledger/census?from=2026-08-06T00:30:00Z&to=2026-08-07T00:30:00Z"
```

Observed: `{"error":"unauthorized"}`.

## 5. The auth gate eats the 422 — every input is a 403 on prod today

```
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $CLOUD_TOKEN" \
  "https://api.barkpark.cloud/v1/operator/deploy-ledger/census"
```

Observed: `403` — while `cloud/test/barkpark_cloud/deploy_ledger_test.exs:955` asserts
`422 invalid_window` for an ALLOWLISTED user. The window branch is unreachable on prod.

## 6. The emitter, and why the two 403 causes are byte-identical

```
git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '333,341p'
git grep -n -A12 "def platform_admin_emails" origin/main -- cloud/lib/barkpark_cloud/notifications.ex
```

`require_platform_operator/2` is one `cond`: allowlist-empty and
not-on-a-populated-allowlist both fall to the SAME
`forbidden(conn, required: "platform_operator", scope: "platform")`.
`platform_admin_emails/0` also returns `[]` when the configured email is not a
REGISTERED user (`Accounts.get_user_by_email` → `reject(&is_nil/1)`), so setting
the env var to an unregistered address leaves the census dark with the same body.

## 7. No reader exists in any client

```
git grep -rn "deploy-ledger\|deploy_census\|deploy-census" origin/main -- internal/ js/ web/
```

Observed: empty.

## 8. The two body shapes a reader must tell apart

```
git show origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex | sed -n '484,494p'
```

200 carries `volume`, `failed`, `failure_rate{pct,sample,refused,reason}`, `classes`,
`deferred`, `not_attempted`, `sites`, `min_sample`. The 403 carries NONE of them —
so `body["failed"] || 0` renders a comforting `0` on a refusal.
