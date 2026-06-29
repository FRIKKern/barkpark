defmodule BarkparkCloud.Accounts.Authz do
  @moduledoc """
  Authorization over Team memberships — the Cloud mirror of api/'s
  `Barkpark.Tenancy.Auth` (`workspace_admin?/2`, `membership_role/2` at
  `api/lib/barkpark/tenancy/auth.ex`). The role IS the grant
  (`team_memberships.role` ∈ owner/admin/member); authority is read from the
  membership row, never derived from anything global about the user — the same
  per-grant insight as the api/ cross-tenant P0 fix (barkpark-23yi).

  `authorize/3` is the single entry point and is TOTAL — an unknown action, a
  non-member, or a nil role returns `{:error, :forbidden}`, never raises (we
  deliberately avoid Coolify's `Role::from` unknown-role throw, see
  `app/Enums/Role.php`).

  ## Policy table (action → minimum grant)

      :read             member   — any GET / list / subscription read
      :launch           admin    — provisions a BILLED box (go-live / launch)
      :delete_barkpark  admin    — tears a box out of the fleet (DELETE / retry)
      :connect_provider admin    — stores a cloud credential at rest
      :manage_members   admin    — add / role-change / remove (teams feature)
      :billing          owner    — spend money / change plan
      :delete_team      owner    — destroy the team

  Reads stay at `member`; money- and infra-destructive actions gate higher.
  This mirrors Coolify, where a `member` can CRUD resources but cannot mint a
  `root` token or manage the team.
  """
  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.{Team, TeamMembership, User}

  @type action ::
          :read
          | :launch
          | :delete_barkpark
          | :connect_provider
          | :manage_members
          | :billing
          | :delete_team
  @type actor :: User.t() | binary()
  @type team :: Team.t() | binary()

  # Ranked roles — the anti-escalation backbone (Coolify `app/Enums/Role.php`
  # `Role::rank`). member < admin < owner.
  @rank %{"member" => 1, "admin" => 2, "owner" => 3}
  @admin_roles ~w(owner admin)

  # Which membership roles satisfy each action (the policy table above). Data,
  # not branching — a future action is one map entry.
  @action_min %{
    read: ~w(owner admin member),
    launch: @admin_roles,
    delete_barkpark: @admin_roles,
    connect_provider: @admin_roles,
    manage_members: @admin_roles,
    billing: ~w(owner),
    delete_team: ~w(owner)
  }

  @doc "The actor's role string in `team`, or nil when not a member."
  @spec role(actor(), team()) :: String.t() | nil
  def role(actor, team) do
    case Accounts.get_membership(team, actor) do
      %TeamMembership{role: role} -> role
      nil -> nil
    end
  end

  @doc "True when the actor's role confers team-admin authority (owner or admin)."
  @spec team_admin?(actor(), team()) :: boolean()
  def team_admin?(actor, team), do: role(actor, team) in @admin_roles

  @doc "True only when the actor is the team OWNER (billing / delete-team gate)."
  @spec team_owner?(actor(), team()) :: boolean()
  def team_owner?(actor, team), do: role(actor, team) == "owner"

  @doc """
  Authorize `actor` to perform `action` in `team`. `:ok` when their grant
  satisfies the action; `{:error, :forbidden}` otherwise. Total — an unknown
  action or a non-member ⇒ forbidden.
  """
  @spec authorize(actor(), team(), action()) :: :ok | {:error, :forbidden}
  def authorize(actor, team, action) do
    allowed = Map.get(@action_min, action, [])

    if allowed != [] and role(actor, team) in allowed do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @doc "Numeric rank of a role string (member 1 < admin 2 < owner 3), 0 if unknown."
  @spec rank(String.t() | nil) :: non_neg_integer()
  def rank(role), do: Map.get(@rank, role, 0)

  @doc """
  Anti-escalation guard (Coolify `app/Models/Member.php` — an admin cannot
  promote past their own rank). The actor must be a team admin AND must not
  grant a role at or above their OWN rank: an admin can add a member but cannot
  mint an owner; an owner can grant admin/member. Returns `:ok |
  {:error, :forbidden}`.
  """
  @spec can_grant?(actor(), team(), String.t()) :: :ok | {:error, :forbidden}
  def can_grant?(actor, team, target_role) do
    actor_rank = rank(role(actor, team))

    cond do
      not team_admin?(actor, team) -> {:error, :forbidden}
      rank(target_role) > actor_rank -> {:error, :forbidden}
      true -> :ok
    end
  end
end
