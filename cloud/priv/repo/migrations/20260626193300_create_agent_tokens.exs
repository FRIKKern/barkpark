defmodule BarkparkCloud.Repo.Migrations.CreateAgentTokens do
  use Ecto.Migration

  # Revocable bearer tokens an on-box agent uses to authenticate its reports.
  # Belongs to a Barkpark. Mirrors api/'s api_tokens: only a token_hash
  # (SHA-256 hex) is stored — never the plaintext, which is shown once at mint.
  # revoked_at / expires_at gate validity; `scope` is the approved-command
  # scope. The unique index on token_hash both enforces no-collisions and backs
  # the verify-by-hash lookup.
  def change do
    create table(:agent_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :barkpark_id, references(:barkparks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token_hash, :string, null: false
      add :scope, :string
      add :revoked_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_tokens, [:barkpark_id])
    create unique_index(:agent_tokens, [:token_hash])
  end
end
