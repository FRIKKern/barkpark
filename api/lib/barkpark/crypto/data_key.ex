defmodule Barkpark.Crypto.DataKey do
  @moduledoc """
  A per-scope Data Encryption Key (DEK), stored wrapped by the master KEK.

  See `Barkpark.Crypto.DataKeys` for the get-or-create / rotation logic and
  `Barkpark.Crypto.KeyProvider` for the wrap/unwrap seam. The plaintext DEK is
  never persisted — only `wrapped_key` (Base64 of the KEK-sealed DEK).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "data_keys" do
    field :scope, :string
    field :version, :integer, default: 1
    field :wrapped_key, :string
    field :kek_version, :integer, default: 1
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(data_key, attrs) do
    data_key
    |> cast(attrs, [:scope, :version, :wrapped_key, :kek_version, :active])
    |> validate_required([:scope, :version, :wrapped_key, :kek_version])
    |> unique_constraint([:scope, :version], name: :data_keys_scope_version_index)
  end
end
