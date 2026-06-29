defmodule Barkpark.Repo.Migrations.CreateUserEmailTokens do
  use Ecto.Migration

  # Single-use, hashed email tokens for verify-email + password-reset (Phase 1).
  # Multi-context, discriminated by `context` ("confirm" | "reset"). Only the
  # SHA-256 hash is stored; the plaintext goes out in the email link and is
  # unrecoverable. `sent_to` pins the token to the address it was mailed to (so a
  # later email change can't be confirmed by an old link). `expires_at` bounds
  # validity; rows are deleted on use. Mirrors Phoenix phx.gen.auth UserToken and
  # cloud/'s invitation-token discipline. ADDITIVE.
  def change do
    create table(:user_email_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :context, :string, null: false
      add :sent_to, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_email_tokens, [:token_hash])
    create index(:user_email_tokens, [:user_id, :context])
  end
end
