defmodule Barkpark.Tenancy.Invitation do
  @moduledoc """
  A PENDING seat: a workspace admin asked to seat an existing user, and the
  user has not yet accepted (OWNER RULING 2026-10-03 #7).

  Deliberately NOT a `workspace_memberships` row. Every authorization reader in
  the codebase treats a membership row as a seat; a pending flag on that table
  would have to be honoured by every one of them, and the one that forgot would
  grant access nobody accepted. Accepting deletes this row and creates the
  membership in one transaction (`Barkpark.Tenancy.Members.accept_invitation/2`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspace_invitations" do
    field :user_id, :binary_id
    field :role, :string
    field :invited_by, :string

    belongs_to :workspace, Barkpark.Tenancy.Workspace

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "`valid_roles` mirrors the membership changeset: built-ins plus the workspace's custom roles."
  def changeset(invitation, attrs, valid_roles) do
    invitation
    |> cast(attrs, [:workspace_id, :user_id, :role, :invited_by])
    |> validate_required([:workspace_id, :user_id, :role])
    |> validate_inclusion(:role, valid_roles)
    |> unique_constraint([:workspace_id, :user_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end
end
