defmodule BarkparkCloud.Repo.Migrations.CreateUserTokens do
  use Ecto.Migration

  # USER session tokens (cloud-12a) — the bearer credential a logged-in User
  # presents on the control-plane HTTP API after POST /v1/auth/login. The
  # web-layer twin of agent_tokens: only a token_hash (SHA-256 hex) is stored,
  # never the plaintext (shown once at mint). `expires_at` gates validity;
  # `context` defaults to "session" (room for future token kinds without a new
  # table). The unique index on token_hash enforces no-collisions and backs the
  # verify-by-hash lookup.
  def change do
    create table(:user_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :token_hash, :string, null: false
      add :context, :string, null: false, default: "session"
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:token_hash])
  end
end
