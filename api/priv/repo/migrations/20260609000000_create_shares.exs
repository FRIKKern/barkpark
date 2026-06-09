defmodule Barkpark.Repo.Migrations.CreateShares do
  @moduledoc """
  P4 — the persistent share registry.

  Backs `Barkpark.Sharing.StoredShare`. A row is the durable twin of a
  `Sharing.Share`: a tenant scope (workspace / project / dataset slugs) plus the
  surfaces it exposes and the access level. The static `BARKPARK_SHARES` env
  config and these rows are MERGED into the live `:shares` by
  `Barkpark.Sharing.refresh/0` — this table is what lets `bp share add/rm`
  (and the Studio) manage shares at runtime without a restart or an env edit.

  A scope (the triple) has AT MOST ONE row — adding a share for a scope that
  already has one REPLACES its surfaces/access (upsert on the unique index).
  """
  use Ecto.Migration

  def change do
    create table(:shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_slug, :text, null: false
      add :project_slug, :text, null: false
      add :dataset, :text, null: false
      add :surfaces, {:array, :text}, null: false
      add :access, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:shares, [:workspace_slug, :project_slug, :dataset],
             name: :shares_scope_index
           )
  end
end
