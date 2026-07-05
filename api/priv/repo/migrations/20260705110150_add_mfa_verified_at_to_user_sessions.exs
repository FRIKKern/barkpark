defmodule Barkpark.Repo.Migrations.AddMfaVerifiedAtToUserSessions do
  use Ecto.Migration

  # Step-up MFA: the timestamp of the most recent successful MFA factor
  # (TOTP or recovery code) presented on THIS session. `require_recent_mfa`
  # reads it to gate sensitive actions; a stale/absent value forces a fresh
  # challenge. Nullable — a session that has never stepped up is simply not
  # "fresh", which is the correct default.
  def change do
    alter table(:user_sessions) do
      add :mfa_verified_at, :utc_datetime_usec
    end
  end
end
