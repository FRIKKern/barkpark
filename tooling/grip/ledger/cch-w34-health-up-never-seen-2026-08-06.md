# cch-w34 verifier recipe — health='up' on a box never heard from, and the trial blind-spot question

Date: 2026-08-06. Tree of record: `origin/main` (local primary checkout was 466 commits
BEHIND origin/main at the time — every local `mix test` result here is L4 at best).

## 1. The three production boxes (L1 — running system)

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT slug, mode, health_status, agent_status, last_seen_at, unreachable_count, unreachable_notification_sent, inserted_at FROM barkparks ORDER BY inserted_at\""
```

Expect 3 rows with `health_status=up`, `agent_status=offline`, `last_seen_at` NULL,
`unreachable_count=0`, `unreachable_notification_sent=f` (gyldendal ×2, muscle-1).

## 2. The two writers of health_status='up' (neither writes last_seen_at)

```
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '285,290p;1493,1500p'
```

* `:287` `adopt_barkpark/3` — `%{host: …, health_status: "up"}`; agent_status untouched → schema default `"offline"`.
* `:1496` `upsert_succeeded_barkpark/5` — `%{health_status: "up", host: ip, agent_status: "offline"}` (provision success).

Schema defaults: `git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex | sed -n '135,140p'`
→ `health_status` default `"unknown"`, `agent_status` default `"offline"`, `last_seen_at` nil.

## 3. The staleness sweep can never see them

```
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '738,752p'
```

`stale_online_barkparks/1` requires `b.agent_status == "online"`. The docstring's
promise — "the row has NEVER reported (`last_seen_at IS NULL`) … so a wedged
never-online instance is still caught" — is UNREACHABLE: the only writer of
`agent_status="online"` is the agent report handler
(`cloud/lib/barkpark_cloud/web/router.ex:1252-1280`), which stamps
`last_seen_at: DateTime.utc_now()` in the SAME changeset. Verify no other writer:

```
git grep -n 'agent_status: "online"' origin/main -- cloud/lib   # → no hits
```

Prod replication of the candidate query returns 0 rows while 3 never-seen managed
boxes exist:

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT b.slug FROM barkparks b JOIN subscriptions s ON s.team_id=b.team_id AND s.status='active' WHERE b.mode IN ('managed','byo') AND b.agent_status='online' AND ((b.last_seen_at IS NOT NULL AND b.last_seen_at < now() - interval '10 minutes') OR (b.last_seen_at IS NULL AND b.inserted_at < now() - interval '10 minutes'))\""
```

## 4. The console's two renders of that row

```
git show origin/main:cloud/priv/static/app.js | sed -n '5004,5024p'   # classifyBp → "degraded"
git show origin/main:cloud/priv/static/app.js | sed -n '6330,6346p'   # rail: Health = cap(health) = "Up"; Last seen = fmtWhen(null) = "—"
```

Pill reads `Degraded · Agent offline` (statusOf `:5073-5078`) — grammar of a box that
WAS online. Rail reads `Health: Up`. Neither says "never reported".

## 5. Trial question — REFUTED as a blind spot

```
ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 "docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c \"SELECT plan, status, count(*) FROM subscriptions GROUP BY 1,2\""
git show origin/main:cloud/lib/barkpark_cloud/billing/subscription.ex | sed -n '68p'
git show origin/main:cloud/lib/barkpark_cloud/billing.ex | sed -n '925,940p;1018,1030p'
```

`@statuses ~w(active canceled past_due)` — there is NO `"trialing"`. `grant_trial/1`
and `insert_trial_subscription/1` both write `plan: "trial", status: "active"`.
Production: 18 trial / 1 supporter / 3 forever, ALL `active`. The INNER JOIN covers
trials. Residual blind spot is narrow: `past_due` / `canceled` / no-sub teams
(27 teams, 22 with a sub row; none of the 5 sub-less teams owns a barkpark today).

## 6. Serializer

`barkpark_json/3` (`cloud/lib/barkpark_cloud/web/router.ex:8611-8624`) emits
`last_seen_at` but NOT `unreachable_count` / `unreachable_notification_sent` —
so the staleness bookkeeping is structurally invisible to the console.
`last_seen_at` IS emitted, so an "unknown / never reported" state is
fixture-authorable client-side with no serializer change.
