defmodule Barkpark.Secrets.SecretRecord do
  @moduledoc """
  The persisted run-secret row (`secrets`, keyed by `name`). The `value` is a
  single string encrypted at rest via `Barkpark.EncryptedBinary`; `updated_by`
  records who last wrote it. Access is logged separately by
  `Barkpark.Secrets.SecretAudit`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:name, :string, autogenerate: false}
  schema "secrets" do
    field :value, Barkpark.EncryptedBinary
    field :updated_at, :utc_datetime_usec
    field :updated_by, :string
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :value, :updated_at, :updated_by])
    |> validate_required([:name, :value, :updated_at])
  end
end
