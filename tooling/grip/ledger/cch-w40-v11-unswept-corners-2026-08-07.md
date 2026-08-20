# cch wave 40 — v11 unswept-corners re-derivation recipes (2026-08-07)

Baseline: `origin/main` = `95642c5500119d5ef5bb938a47516cacb5ab0f05`.

## R1 — the "Send test" email rides the PLATFORM transport, always

```sh
git show origin/main:cloud/lib/barkpark_cloud/notifications/transactional.ex | sed -n '82,110p'
git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '310,331p'
git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '545,557p'
```

`Transactional.deliver_test/1` = `Mailer.deliver/1` (no override). `deliver_alert/2`
uses `Mailer.deliver(email, override)` for `transport: "smtp"`. `Notifications.deliver_test/2`
reads `settings` for the rate limit and `team_id` only — never `settings.transport`.
Body claims: `"If you received it, your notification email is working."`

## R2 — owner-only remedies fanned out to every member

```sh
git show origin/main:cloud/lib/barkpark_cloud/notifications.ex | sed -n '466,472p'   # team_member_emails fan-out
git show origin/main:cloud/lib/barkpark_cloud/notifications/event_email.ex | sed -n '77,81p'
git show origin/main:cloud/lib/barkpark_cloud/workers/trial_expiry_worker.ex | sed -n '122,127p'
git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '445,461p'   # require_primary_team_owner
```

## R3 — POST /v1/tokens has exactly one 403 exit

```sh
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5094,5150p'
git show origin/main:cloud/lib/barkpark_cloud/web/auth.ex | sed -n '48,60p'   # require_user -> unauthorized only
```

## R4 — POST /v1/invitations/accept has exactly one 403 exit

```sh
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '5022,5066p'
```

## R5 — the four surfaces are otherwise clean

```sh
grep -rnE '"[^"]*\b(You|you|your|Your|Upgrade|Contact|Please|permission|owner|admin)\b[^"]*"' \
  cloud/lib/barkpark_cloud/mailer.ex cloud/lib/barkpark_cloud/webhooks/ \
  cloud/lib/barkpark_cloud/workers/ cloud/lib/barkpark_cloud/sites/auto_deploy_worker.ex
```

## R6 — ENV WARNING: local cloud test DB is contaminated

```sh
cd cloud && CC=clang MIX_ENV=test mix ecto.migrations | tail -8   # FILE NOT FOUND rows
cd cloud && CC=clang mix test test/barkpark_cloud/notifications_test.exs   # 17/26 fail, 42703 undefined_column
cd cloud && CC=clang mix test test/barkpark_cloud/ --only smoke   # 0 tests, rc=1 (no `smoke` tag exists)
```
