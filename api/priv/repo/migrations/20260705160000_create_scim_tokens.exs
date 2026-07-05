defmodule Barkpark.Repo.Migrations.CreateScimTokens do
  @moduledoc """
  era-w4-scim-users — a per-Organization SCIM bearer token. An IdP authenticates
  to `/scim/v2/*` with this token; it is scoped to exactly ONE organization, so
  a token for org A can never touch org B's users. Only the SHA-256 hash is
  stored (mirrors api_tokens).
  """
  use Ecto.Migration

  def change do
    create table(:scim_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :token_hash, :string, null: false
      add :label, :string
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scim_tokens, [:token_hash])
    create index(:scim_tokens, [:organization_id])
  end
end
