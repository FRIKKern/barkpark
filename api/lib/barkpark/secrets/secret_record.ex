defmodule Barkpark.Secrets.SecretRecord do
  @moduledoc """
  The persisted run-secret row (`secrets`, surrogate `id` PK). The `value` holds
  the raw at-rest ciphertext bytes (a `bytea`); `updated_by` records who last
  wrote it. Access is logged separately by `Barkpark.Secrets.SecretAudit`.

  ## Per-tier crypto codec (connectors D201, option C) — NOT an Ecto type

  `value` is a plain `:binary` column: `Barkpark.Secrets` runs an EXPLICIT
  per-tier codec instead of an automatic `Barkpark.EncryptedBinary` cast, because
  the two tiers use different cipher paths:

    * GLOBAL row (`workspace_id` nil) — `Barkpark.Vault.encrypt!/1` /
      `decrypt/1` (exactly what `EncryptedBinary` delegated to; on-disk bytes
      stay byte-identical, so the prod `ingest_token` keeps round-tripping).
    * SCOPED row (`workspace_id` set) — the `Barkpark.Crypto.FieldCipher`
      envelope (Jason-encoded) keyed by the per-`(workspace_id, "run-secrets")`
      DEK (`Barkpark.Crypto.DataKeys`, D51-D54). A row physically MOVED to
      another workspace decrypts under the WRONG DEK → GCM tag mismatch →
      fail-closed: the tenant wall is now CRYPTOGRAPHIC, not SQL-only (D196a).

  Reads branch on the ROW's own `workspace_id`; the context seals any decrypt
  failure to the tier's opaque-absent reply. No migration, no new column — zero
  scoped rows exist in prod at land time.

  Two-tier identity (connectors D191): a NULL `workspace_id` row is
  INSTANCE-GLOBAL (unique per `name` — `secrets_global_name_index`); a non-NULL
  row belongs to exactly one workspace (unique per `{workspace_id, name}` —
  `secrets_workspace_name_index`), so the same name may coexist per workspace
  and globally. BOTH named `unique_constraint`s below are load-bearing (D194):
  without them a same-tier duplicate INSERT raises `Ecto.ConstraintError`
  (a 500) instead of returning `{:error, changeset}` (a 409).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "secrets" do
    field :name, :string
    field :value, :binary
    field :updated_at, :utc_datetime_usec
    field :updated_by, :string
    field :workspace_id, :binary_id
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :value, :updated_at, :updated_by, :workspace_id])
    |> validate_required([:name, :value, :updated_at])
    |> unique_constraint(:name, name: :secrets_global_name_index)
    |> unique_constraint(:name, name: :secrets_workspace_name_index)
  end
end
