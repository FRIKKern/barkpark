defmodule Barkpark.Secrets.SecretRecord do
  @moduledoc """
  The persisted run-secret row (`secrets`, surrogate `id` PK). The `value` is a
  single string encrypted at rest via `Barkpark.EncryptedBinary`; `updated_by`
  records who last wrote it. Access is logged separately by
  `Barkpark.Secrets.SecretAudit`.

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
    field :value, Barkpark.EncryptedBinary
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
