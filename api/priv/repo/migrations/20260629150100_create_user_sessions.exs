defmodule Barkpark.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  # Browser/login session bearer tokens for `users` (Phase 1 of core auth).
  # Hash-at-rest discipline (mirrors api_tokens + cloud/'s UserToken): only a
  # SHA-256 `token_hash` is stored, never the plaintext. `revoked_at` is the
  # kill switch (single-device logout / "sign out everywhere" on password
  # change); `expires_at` bounds lifetime; device metadata backs an
  # active-sessions UI. ADDITIVE — no existing data touched.
  def change do
    create table(:user_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :context, :string, null: false, default: "session"
      add :expires_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec
      add :ip_address, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_sessions, [:token_hash])
    create index(:user_sessions, [:user_id])
  end
end
