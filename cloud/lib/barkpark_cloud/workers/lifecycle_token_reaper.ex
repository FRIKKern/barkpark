defmodule BarkparkCloud.Workers.LifecycleTokenReaper do
  @moduledoc """
  Per-minute hygiene sweep of dead `"reset"` / `"confirm"` / `"change_email"`
  `user_tokens` rows — the fifth reaper on the `:maintenance` queue, beside
  `DeviceAuthReaper`, `OAuthStateReaper`, `SseTicketReaper` and
  `OAuthExchangeReaper`.

  Same defect class as all four: a row nothing ever deletes. Before this worker,
  `grep delete_all` over `Accounts` found exactly one delete per context for
  `session` (explicit teardown), `2fa_pending`, `sse` and `oauth_exchange` — and
  NOTHING for these three. Every one of them soft-stamps instead:

    * `reset` — `revoke_reset_tokens/2` stamps `revoked_at` on supersede AND on
      consume. Every password-reset link a user ever requested is still a row.
    * `confirm` — a 7-day single-use token, revoked by `confirm_user/1`.
    * `change_email` — a 10-minute 6-digit code, revoked on success and on the
      `failed_attempts` lockout.

  Correctness never depends on this running. Every reader
  (`user_by_valid_lifecycle_token/2`, the `FOR UPDATE` change-code lookup,
  `reset_password_by_token/2`) already filters `is_nil(revoked_at)` and a live
  `expires_at`, so a burned or lapsed row is unusable the instant either becomes
  true. What this stops is the ACCRETION.

  ## THE GRACE RULING — WHY THIS DIVERGES FROM SseTicketReaper / OAuthStateReaper

  Those two carry an explicit NO-GRACE ruling: they delete at
  `revoked_at IS NOT NULL OR expires_at <= now`, exactly. That ruling was
  examined here and DELIBERATELY NOT COPIED, because the premise it rests on —
  "nothing downstream reads a lapsed row" — is FALSE for these three contexts.

  `Accounts.throttled?/3` implements the email-delivery throttles
  `@confirm_throttle` (1 per 300s) and `@change_email_throttle` (3 per 3600s) by
  COUNTING rows:

      where user_id == ^uid and context == ^context
      where is_nil(revoked_at) and inserted_at >= ^since

  It filters `revoked_at`. It does NOT filter `expires_at`. So an
  expired-but-unrevoked row is still a live vote against the throttle, and
  deleting it the moment it lapses would hand the caller a resend slot EARLY —
  spam email delivery, the exact outbound side effect those throttles exist to
  bound. `change_email` is the sharp case: a 10-minute TTL under a 3600s window,
  so the row keeps counting for 3000s after it expires.

  So the condition is SPLIT rather than uniform (`Accounts.reap_lifecycle_tokens/0`):

    * `revoked_at IS NOT NULL` → reaped with NO grace, exactly like the twins.
      `throttled?/3` already excludes revoked rows, so the count cannot move.
    * `expires_at <= now - 7200s` → reaped only after a grace window that is
      DOUBLE the largest throttle window (3600s). A row stops counting at
      `inserted_at + window`, and `expires_at >= inserted_at` for every mint
      here, so `expires_at + grace` is always past the point the throttle
      released it. Pinned by test against the throttle constants themselves, so
      raising a window without raising the grace REDS.

  The alternative shape — reap ONLY `revoked_at` rows and let lapsed-unrevoked
  ones live forever — was rejected: an unclicked reset link and an unclicked
  confirm link are never revoked by anything, so that shape leaves the single
  largest source of the accretion in place and does not pay the row.

  ## COVERAGE BOUNDARY — what this does NOT do

  It does not widen `reap_sse_tickets/0`. That sweep's `context == "sse"` clause
  is pinned by its own test precisely so a later slice cannot casually broaden
  it, and its no-grace ruling is the correct answer to a different question.
  This worker is strictly the three lifecycle contexts; `session`, `pat`,
  `2fa_pending` and `device` keep their own owners.

  It also bounds the RESIDUE, not the MINT RATE — the throttles above are the
  mint-rate guard, and they are what this worker is built around rather than
  against.

  Idempotent: a sweep that finds nothing returns `{:ok, %{reaped: 0}}` and never
  raises. The `unique` window (60s) collapses a slow sweep plus the next cron
  tick into one in-flight job instead of stacking.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, BarkparkCloud.Accounts.reap_lifecycle_tokens()}
  end
end
