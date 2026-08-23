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

  # Role rank — the Cloud encoding of Coolify's `App\Enums\Role::rank()`
  # (member=1 < admin=2 < owner=3). Kept on the schema that already owns @roles
  # so "admin can't grant owner" / "can't act on a higher rank" lives in ONE
  # place and the context (not the route/LiveView) enforces it.
  @ranks %{"member" => 1, "admin" => 2, "owner" => 3}

  @doc "Integer rank of a role (member<admin<owner); 0 for an unknown role."
  def rank(role), do: Map.get(@ranks, role, 0)

  @doc """
  Every role this ladder ranks. Exists so a census can DERIVE its role domain
  from `@ranks` instead of re-typing it — a re-typed literal pins itself and
  catches nothing when a role is added to one ladder only.
  """
  def ranked_roles, do: Map.keys(@ranks)

  @doc "True when `role` is an admin-or-higher grant (owner|admin)."
  def admin?(role), do: rank(role) >= rank("admin")

  @doc "True when `actor_role` strictly outranks `target_role` (Coolify's `Role::gt/1`)."
  def outranks?(actor_role, target_role), do: rank(actor_role) > rank(target_role)

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:user_id, :team_id, :role])
    |> validate_required([:user_id, :team_id, :role])
    |> validate_inclusion(:role, @roles)
    |> assoc_constraint(:user)
    |> assoc_constraint(:team)
    |> unique_constraint([:user_id, :team_id],
      name: :team_memberships_user_team_unique_idx,
      message: "is already a member of this team"
    )
  end
end
