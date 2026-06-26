defmodule BarkparkCloud.Accounts.TeamMembership do
  @moduledoc """
  Binds a User to a Team with a role — the Cloud mirror of api/'s
  `Barkpark.Tenancy.Membership`. The role IS the grant (owner/admin/member);
  it is not derived from anything about the user. A user is in a team at most
  once, enforced by the composite UNIQUE (user_id, team_id).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner admin member)
  # Default role for a NEW membership when no explicit role is passed — mirrors
  # the api/ tenancy rule (`@default_role member`): a user ADDED to a team is a
  # `member` unless the caller explicitly grants higher (the team CREATOR gets
  # "owner" via `Accounts.create_team_with_owner`-style flows).
  @default_role "member"

  schema "team_memberships" do
    field :role, :string, default: @default_role

    belongs_to :user, BarkparkCloud.Accounts.User
    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def roles, do: @roles
  def default_role, do: @default_role

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :team_id, :role])
    |> validate_required([:user_id, :team_id, :role])
    |> validate_inclusion(:role, @roles)
    |> assoc_constraint(:user)
    |> assoc_constraint(:team)
    |> unique_constraint([:user_id, :team_id],
      name: :team_memberships_user_team_unique_idx,
      message: "user is already a member of this team"
    )
  end
end
