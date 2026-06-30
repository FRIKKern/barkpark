defmodule Barkpark.Repo.Migrations.CreateDataKeys do
  use Ecto.Migration

  # Envelope-encryption key store (Phase 0 of core auth/secrets).
  #
  # Each row is a per-SCOPE Data Encryption Key (DEK), stored ONLY in wrapped
  # form — `wrapped_key` is the DEK sealed by the master KEK (see
  # Barkpark.Crypto.KeyProvider / LocalKek). Plaintext DEKs never touch the DB;
  # they are unwrapped on demand and cached in memory.
  #
  #   scope        — what the DEK protects, e.g. "dataset:<uuid>" / "global".
  #   version      — DEK generation for this scope (rotate = new version row).
  #   wrapped_key  — Base64(KEK-encrypted DEK).
  #   kek_version  — which KEK generation sealed this DEK (KEK rotation re-wraps
  #                  in place and bumps this).
  #   active       — exactly one active DEK per scope; new writes use it.
  #
  # ADDITIVE: a fresh table, no existing data touched. With no `encrypted: true`
  # fields declared anywhere, nothing reads or writes it.
  def change do
    create table(:data_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      add :version, :integer, null: false, default: 1
      add :wrapped_key, :text, null: false
      add :kek_version, :integer, null: false, default: 1
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    # One row per (scope, version); fast lookup of the active DEK per scope.
    create unique_index(:data_keys, [:scope, :version])
    create index(:data_keys, [:scope, :active])
  end
end
