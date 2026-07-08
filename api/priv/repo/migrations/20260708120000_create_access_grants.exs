defmodule Barkpark.Repo.Migrations.CreateAccessGrants do
  use Ecto.Migration

  # Airdrop grants: a time-boxed, account-bound, scoped capability minted by an
  # existing principal for a grantee (identified by email until claimed).
  #
  # The raw link token is NEVER stored — only its SHA-256 hash (unique). "Active"
  # is a DERIVED in-query predicate (revoked_at IS NULL AND not-expired AND
  # (not single_use OR unclaimed)), never a column, so there is nothing to drift.
  def change do
    create table(:access_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Account-binding: the minting principal (a user or api_token id). Not a
      # FK — the principal kind is polymorphic (mirrors workspace_memberships'
      # principal_id), and the audit breadcrumb must survive principal deletion.
      add :grantor_id, :binary_id, null: false

      add :grantee_email, :string, null: false
      # NULL until claimed → then the claiming user's id.
      add :grantee_user_id, :binary_id

      # Scope ladder: workspace (required top) → project → dataset → type →
      # doc_id. A NULL below workspace means "everything at that level".
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, :binary_id
      add :dataset, :string
      add :type, :string
      add :doc_id, :string

      add :capabilities, {:array, :string}, null: false

      # SHA-256 hex of the raw token; the raw token is returned once at mint.
      add :link_token_hash, :string, null: false
      add :single_use, :boolean, null: false, default: false

      add :expires_at, :utc_datetime_usec
      add :claimed_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:access_grants, [:link_token_hash])
    create index(:access_grants, [:grantee_user_id])
    create index(:access_grants, [:workspace_id])
  end
end
