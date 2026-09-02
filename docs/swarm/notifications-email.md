<!-- doc-tier: cold | canonical-for: swarm-notifications-email | budget: 4000tok -->
# notifications-email — provenance note

> HISTORICAL RECORD (2026-06-29) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

**Slug:** `notifications-email` · **Target app:** `cloud/` (`BarkparkCloud`) · **Status:** candidate (judge before merge)

## What this adds

The shared **mailer** for Barkpark Cloud plus two layers on top of it:

1. **Transactional email** (the beta blocker) — invite / password-reset / email-verification / test, always over the **platform** transport (`BarkparkCloud.Mailer`), so onboarding works even before a team configures any SMTP.
2. **Per-team event notifications** — a `email_notification_settings` row per team (transport + per-event toggles + encrypted SMTP secrets — SIX events today, not the nine this shipped with: `deployment_succeeded`, `member_invited` and `token_expiring` were dropped, because every atom in `@events` must have a producer), a `dispatch_event/3` dispatcher with an `@always_send` allowlist and a team-members-only recipient guard, and a durable `notification_deliveries` log.

The mailer dependency is the prerequisite every email-bearing cloud feature waits on (teams-invite, auth-reset, billing-dunning), which is why this candidate ships it first.

## Why `cloud/` (not `api/`)

Per the brief's placement rule: account / team / notification / billing convenience lands in `cloud/`. The feature is team-scoped and rides the existing `cloud/` contexts (Accounts, Registry.Vault, Billing). `cloud/` is Plug+Bandit (not LiveView), so the surface is **JSON routes + a vanilla SPA pane**, not a LiveView.

## Coolify source anchors

- `app/Models/EmailNotificationSettings.php` — 1 row/team, encrypted SMTP columns, ~14 `*_email_notifications` booleans → `BarkparkCloud.Notifications.EmailSettings`.
- `app/Traits/HasNotificationSettings.php` — `getEnabledChannels`, `$alwaysSendEvents`, per-event toggle → `EmailSettings.event_enabled?/2` + `Notifications` `@always_send` + `should_send?/2`.
- `app/Notifications/Channels/EmailChannel.php` — resolve transport → recipients → render → send; recipients restricted to team members (the data-exfiltration guard) → `Notifications.dispatch_event/3`.
- `app/Notifications/Channels/TransactionalEmailChannel.php` — identity email always on the instance transport → `Notifications.Transactional` over the platform `Mailer`.
- `app/Models/Team.php:59` — auto-create settings on team create → `Notifications.ensure_settings/1` inside the signup `Repo.transaction`, with a lazy `get_or_create_settings/1` backstop.
- `app/Notifications/CustomEmailNotification.php` (`ShouldQueue`, retries) — async retry → modeled as the durable `notification_deliveries` row (sync send for v1; the table is the future Oban retry seam).
- `app/Livewire/Notifications/Email.php` — settings page + 10s test rate-limit → `GET/PUT /v1/notifications/settings`, `POST /v1/notifications/test`, and the SPA "Notifications" pane.

## Barkpark patterns reused

- **Encryption at rest:** `BarkparkCloud.Registry.Vault.encrypt/1` / `decrypt/1` (AES-256-GCM, key from config), exactly as `Registry.connect_provider/3` does for `Provider.encrypted_token`. No parallel vault.
- **Config-selected adapter:** the `Mailer` adapter is chosen from config (Local dev / Test test / SMTP prod) — the same seam as `Billing.Gateway` and `Registry.Vault`. No secrets in code; prod SMTP creds from `SMTP_*` env in `runtime.exs`.
- **Durable delivery log:** `notification_deliveries` mirrors `api/lib/barkpark/webhooks/delivery.ex` (`status` / `attempts` / `last_error`).
- **Schema shape:** `EmailSettings` / `Delivery` mirror `Registry.Provider` (binary_id, `assoc_constraint(:team)`, `redact: true` on every ciphertext field).
- **Router conventions:** `Auth.require_user`, `conn.assigns.current_team`, `errors/1` for 422 details, the `no_team` 422 — copied from the existing `/v1/providers` handlers.

## Files added

```
cloud/lib/barkpark_cloud/mailer.ex                         platform mailer (config-selected adapter)
cloud/lib/barkpark_cloud/notifications.ex                  context: settings + transactional + dispatch
cloud/lib/barkpark_cloud/notifications/email_settings.ex   per-team settings schema
cloud/lib/barkpark_cloud/notifications/delivery.ex         durable send-record schema
cloud/lib/barkpark_cloud/notifications/transactional.ex    invite/reset/verify/test builders
cloud/lib/barkpark_cloud/notifications/event_email.ex      per-event alert body builder
cloud/priv/repo/migrations/20260629120200_create_email_notification_settings.exs
cloud/priv/repo/migrations/20260629120300_create_notification_deliveries.exs
cloud/test/barkpark_cloud/notifications_test.exs           context tests
cloud/test/barkpark_cloud/web/router_notifications_test.exs route tests
docs/swarm/notifications-email.md                          this note
```

## Files changed

- `cloud/mix.exs` — add `{:swoosh, "~> 1.16"}`, `{:gen_smtp, "~> 1.2"}`.
- `cloud/config/config.exs` — `Mailer` adapter `Swoosh.Adapters.Local`, `Notifications` from defaults, `config :swoosh, :api_client, false`.
- `cloud/config/test.exs` — `Mailer` adapter `Swoosh.Adapters.Test`.
- `cloud/config/runtime.exs` — prod `Mailer` over `Swoosh.Adapters.SMTP` from `SMTP_*` / `MAIL_FROM_*` env.
- `cloud/lib/barkpark_cloud/accounts.ex` — `list_team_member_emails/1` (the recipient query + exfiltration guard) + a `team_id/1` helper.
- `cloud/lib/barkpark_cloud/web/router.ex` — three routes; `Notifications.ensure_settings` in the signup tx; additive `dispatch_event` at provision succeed/fail, agent health flip, subscription past_due; `dispatch_barkpark_event/3` + `maybe_dispatch_health_flip/3` helpers.
- `cloud/priv/static/{index.html,app.js}` — a "Notifications" SPA pane (transport, per-event toggles, masked SMTP fields, a "Send test" button).

## How to test

```bash
cd cloud
mix deps.get            # fetches swoosh + gen_smtp
mix ecto.migrate        # applies the two new migrations
mix test test/barkpark_cloud/notifications_test.exs \
          test/barkpark_cloud/web/router_notifications_test.exs
```

The context test uses `Swoosh.Adapters.Test` (`assert_email_sent` / `refute_email_sent`) — no network. It covers changeset validation, the secret encrypt-round-trip + masking, auto-create idempotency, the dispatcher (toggle on/off, `always_send`, alerts-disabled mute, the team-members-only guard), the transactional builders over the platform transport, and the 10s test rate-limit. The router test covers auth (401), masking, 422 on a bad port, and 200-then-429 on the test send.

Dev mailbox: `Swoosh.Adapters.Local` keeps sent mail in memory (a `/dev/mailbox` route can surface it if added later).

## Caveats / honest deferrals

- **Async retry needs Oban. OBAN HAS SINCE LANDED IN `cloud/`** (`{:oban, "~> 2.17"}`, an `{Oban, ...}` child in `application.ex`, a live `Oban.Plugins.Cron` crontab and 14 workers), and `dispatch_event/3`'s chat leg is enqueued through it. The EMAIL leg still sends **synchronously**. A slow SMTP send blocks the trigger path; the dispatcher swallows errors (never raises into the SSE broadcast) and records a `failed` delivery. The `notification_deliveries` (`attempts`, `last_error`) shape is the retry seam for when Oban lands.
- **No RBAC gate on the settings routes — FIXED; all three sub-claims are now false.** `Accounts.Authz.team_admin?/2` exists, and both `PUT /v1/notifications/settings` and `POST /v1/notifications/test` open with `Auth.require_team_admin(conn, [])`. A plain team member can no longer edit settings or send a test.
- **`api` (hosted-provider) transport is deferred.** SMTP was chosen as the platform transport to avoid a Finch/Hackney HTTP-client dep (matching the Billing layer's `:httpc` posture). The `"api"` transport value and the `api_key_encrypted` schema field were subsequently DELETED rather than left as a dead offer — `@transports` is `~w(instance smtp)`. Only the unselected DB column remains.
- **`member_invited` / `token_expiring` were RETIRED, not left pending.** Their columns were dropped and the dispatcher no longer accepts them: an atom in `@events` with no producer reds the Console gate, so the promise was removed rather than carried.
- **`subscription_past_due` fires only if Billing surfaces a `past_due` subscription** from the webhook. Today `handle_webhook/2` returns an `active` subscription on activation; the dispatch is additive and guarded on `sub.status == "past_due"`, so it lights up the moment Billing emits that state.
- **The failed-delivery path is not exercised in tests.** The Test adapter always succeeds; the `failed` branch (status + `last_error`) is covered by reading, not by an assertion (no hermetic way to force an SMTP failure without a network). Verified by inspection.
- **`mix format` not run** — the project's `.formatter.exs` uses `import_deps`, which needs fetched deps (absent in the worktree). Code was hand-written to the surrounding style; run `mix format` after `mix deps.get` before merge.
- **Migrations are NOT run** (per the brief). They are additive (two new tables, FK `on_delete: :delete_all` to `teams`).
