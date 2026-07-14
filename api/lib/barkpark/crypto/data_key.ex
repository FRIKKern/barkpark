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
    # Per-workspace attribution (bpb-datakeys-write-path-workspace-attribution,
    # charter D51-D54): NULLABLE FK to `workspaces` so a DEK is keyed by
    # (workspace_id, scope) — a shared-slug DEK travels via the E1 `workspace_id`
    # export/teardown path, and workspace A + workspace B may each hold an active
    # DEK for the same `"dataset:<slug>"` scope. STAMPED by the runtime write
    # path (`DataKeys.insert_version!/3`). A NULL value = a legacy/dormant DEK
    # (the FieldCipher direct path with no workspace), excluded from per-workspace
    # bundles (the D44 forward-guard).
    field :workspace_id, :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(data_key, attrs) do
    data_key
    |> cast(attrs, [:scope, :version, :wrapped_key, :kek_version, :active, :workspace_id])
    |> validate_required([:scope, :version, :wrapped_key, :kek_version])
    |> unique_constraint([:workspace_id, :scope, :version],
      name: :data_keys_ws_scope_version_index
    )
  end
end
