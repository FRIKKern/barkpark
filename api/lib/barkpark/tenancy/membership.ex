defmodule Barkpark.Tenancy.Membership do
  @moduledoc """
  Binds a principal to a Workspace with a role. The principal is the API
  token (there is NO users/accounts model); `principal_type` defaults to
  "api_token" to leave room for future principal kinds.

  This is the TABLE + changeset only — token-binding and auth enforcement
  live in a sibling task.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner admin member)
  @principal_types ~w(api_token)

  schema "workspace_memberships" do
    field :principal_type, :string, default: "api_token"
    field :principal_id, :binary_id
    field :role, :string

    belongs_to :workspace, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def roles, do: @roles

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:workspace_id, :principal_type, :principal_id, :role])
    |> validate_required([:workspace_id, :principal_id, :role])
    |> validate_inclusion(:principal_type, @principal_types)
    |> validate_inclusion(:role, @roles)
    |> assoc_constraint(:workspace)
    |> unique_constraint([:workspace_id, :principal_type, :principal_id],
      name: :workspace_memberships_principal_unique_idx,
      message: "principal already a member of this workspace"
    )
  end
end
