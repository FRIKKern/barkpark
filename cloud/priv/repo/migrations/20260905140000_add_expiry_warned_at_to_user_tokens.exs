defmodule BarkparkCloud.Repo.Migrations.AddExpiryWarnedAtToUserTokens do
  @moduledoc """
  cch-w30-bl — the one-shot budget for the PAT expiry warning.

  `TokenExpiryWarningWorker` runs daily and must mail each expiring PAT's OWNER
  exactly once, so the "already warned" fact has to live on the token row: the
  worker claims it with an atomic `UPDATE … WHERE expiry_warned_at IS NULL`,
  the same discipline `TrialExpiryWorker` uses for its per-threshold notice
  stamps on `teams`.

  NULLABLE, and never backfilled. A NULL means "this token has not been warned",
  which is the correct reading for every row minted before the worker existed:
  a token already inside the warning window gets its warning on the first pass
  after this migration, which is the behaviour the feature promises.

  It lives on `user_tokens` — the USER-scoped row — and NOT on
  `email_notification_settings`. That is the whole point of the row that filed
  this: the previous `token_expiring` column was a TEAM toggle governing a
  user-scoped fact, and it was dropped (20260804123000) rather than defaulted.
  """
  use Ecto.Migration

  def change do
    alter table(:user_tokens) do
      add :expiry_warned_at, :utc_datetime_usec
    end
  end
end
