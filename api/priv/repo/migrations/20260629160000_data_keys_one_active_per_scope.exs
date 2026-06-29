defmodule Barkpark.Repo.Migrations.DataKeysOneActivePerScope do
  use Ecto.Migration

  # LOW-18 (red-team): enforce the "exactly one ACTIVE DEK per scope" invariant
  # at the DB, not just in app code. `DataKeys.active_dek/1` assumes `Repo.one/1`
  # returns at most one active row for a scope; two active rows (a concurrency
  # bug, a bad manual edit, a partial rotation) makes `Repo.one!` raise and every
  # new encryption for that scope crash. A PARTIAL unique index makes the second
  # active row impossible.
  #
  # Partial (WHERE active) — so the many INACTIVE historical versions per scope
  # (kept decryptable after rotation) are unconstrained; only the single active
  # row is unique per scope. ADDITIVE: indexes a small key table, no data moved.
  def change do
    create unique_index(:data_keys, [:scope],
             where: "active",
             name: :data_keys_one_active_per_scope
           )
  end
end
