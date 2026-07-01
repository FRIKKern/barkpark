defmodule BarkparkCloud.Repo.Migrations.AddEmailVerificationToUsers do
  @moduledoc """
  email-verification-recovery: the columns the confirm + verified-email-change
  flows need, riding the credentials main already ships (session lifecycle +
  `revoked_at` on `user_tokens`, the password-reset `context = "reset"` flow).

    * `users.confirmed_at`   — NULL until the emailed confirm token is proven.
    * `users.pending_email`  — the address awaiting a 6-digit-code confirmation
      during a verified email change (citext, so it compares case-insensitively
      like `users.email`).
    * `user_tokens.sent_to`  — the address a lifecycle token was issued FOR, so
      a change-email code can't be replayed against a different pending target.
    * `user_tokens.failed_attempts` — the per-token wrong-code counter that backs
      the email-change brute-force LOCKOUT (a hard cap, not a mint-rate throttle):
      N wrong codes revokes the token and drops the pending change.

  Purely additive — no drops. `revoked_at` already exists (session-lifecycle
  migration 20260629120100), so it is NOT re-added here.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :confirmed_at, :utc_datetime_usec
      add :pending_email, :citext
    end

    alter table(:user_tokens) do
      add :sent_to, :citext
      add :failed_attempts, :integer, default: 0, null: false
    end
  end
end
