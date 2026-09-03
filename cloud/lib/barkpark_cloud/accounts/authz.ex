defmodule BarkparkCloud.Accounts.Authz do
  @moduledoc """
  Authorization over Team memberships — the Cloud mirror of api/'s
  `Barkpark.Tenancy.Auth` (`workspace_admin?/2`, `membership_role/2` at
  `api/lib/barkpark/tenancy/auth.ex`). The role IS the grant
  (`team_memberships.role` ∈ owner/admin/member); authority is read from the
  membership row, never derived from anything global about the user — the same
  per-grant insight as the api/ cross-tenant P0 fix (barkpark-23yi). "Mirror"
  is a claim about SHAPE ONLY, and as of 2026-08-19 it is nothing to lean on:
  api/'s own moduledoc carries the same totality phantom (`auth.ex:19` and
  `:166`, unfixed on origin/main, in flight as arpss-w9). Nothing below is a
  statement about api/.

  WHAT `authorize/3` ACTUALLY IS, said plainly: the POLICY TABLE, not the
  single entry point. It has ZERO callers in `cloud/lib` (tests only).
  Production reads the very same table through four other functions —
  `team_admin?/2` (`Web.Auth.require_team_admin/2`,
  `require_current_team_admin/1`, and the inline `cond`s in `router.ex`),
  `team_owner?/2` (`require_team_owner/2`, `require_current_team_owner/1`),
  `role/2` (PAT minting, `Accounts.create_personal_access_token/3`) and
  `can_grant?/3` (`Accounts.add_member_as/4`, `update_member_role_as/4`).
  A reader who hardens only `authorize/3` hardens nothing that runs.

  TOTALITY, SAID EXACTLY — the previous wording ("`authorize/3` … is TOTAL …
  never raises") was a phantom warrant, and the honest statement is three
  clauses long:

    * TOTAL OVER RESOLVED INPUTS. Given a `%User{}`/uuid actor and a `%Team{}`
      or uuid team, every entry point here is total: a non-member, an unknown
      action, a string action, and a nil action all return
      `{:error, :forbidden}` / `nil` / `false` and never raise (we deliberately
      avoid Coolify's `Role::from` unknown-role throw, see `app/Enums/Role.php`).
    * LATENTLY NON-TOTAL AT THE CLAUSE LEVEL. Every entry point funnels into
      `Accounts.get_membership/2`, which has THREE clauses and NO catch-all and
      does an UNGUARDED `Repo.get_by` where `Repo.get_by_uuid/2` exists for
      exactly this. So `team = ""` raises `Ecto.Query.CastError` and
      `team = nil` raises `FunctionClauseError` — and `@type team ::
      Team.t() | binary()` below ADMITS both of those inputs.
    * AND NO REQUEST PATH REACHES THAT — by three NAMED guards, not by luck:
      (1) `Web.Auth.resolve_team/2` launders the caller-supplied
      `x-barkpark-team` header through `Accounts.get_team/1` =
      `Repo.get_by_uuid/2` (nil on a malformed id) and falls back to
      `primary_team/1`; that only attacker-controlled surface is already pinned
      by `test/barkpark_cloud/web/router_team_switcher_test.exs:72`, which loops
      `[foreign.id, "not-a-uuid", ""]`. (2) Every gate nil-checks
      `:current_team` before calling in (`gate_role/4`,
      `require_current_team_admin/1`, `require_current_team_owner/1`, and each
      inline `Accounts.team_admin?` `cond` in `router.ex`). (3)
      `Accounts.invite_member/4` and `update_member_role_as/4` pattern-match
      `%Team{}` in their heads, and `with_team_role/3` resolves path params
      through the uuid-guarded `Accounts.get_team/1` first. Measured: 48
      request × header combinations over 6 routes and 2 role postures produced
      200/403/422 only — zero 500s.

  Both halves are now tripwired by
  `test/barkpark_cloud/accounts/authz_call_site_census_test.exs`: ARM 1
  measures the domain — including the raises — so a change that totalises
  `get_membership/2` REDS this paragraph instead of silently staling it; ARM 2
  censuses every `Authz`/`Accounts` membership call site in `cloud/lib` for one
  of the guard forms above, so a new unguarded one reds.

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

  @doc """
  The role literals `team_admin?/2` accepts. Exists so a census can DERIVE its
  role domain from `@admin_roles` instead of re-typing it — a re-typed literal
  pins itself and catches nothing when a role is added to one ladder only.
  """
  @spec admin_roles() :: [String.t()]
  def admin_roles, do: @admin_roles

  @doc "True when the actor's role confers team-admin authority (owner or admin)."
  @spec team_admin?(actor(), team()) :: boolean()
  def team_admin?(actor, team), do: role(actor, team) in @admin_roles

  @doc "True only when the actor is the team OWNER (billing / delete-team gate)."
  @spec team_owner?(actor(), team()) :: boolean()
  def team_owner?(actor, team), do: role(actor, team) == "owner"

  @doc """
  Authorize `actor` to perform `action` in `team`. `:ok` when their grant
  satisfies the action; `{:error, :forbidden}` otherwise. Total over RESOLVED
  inputs — an unknown action or a non-member ⇒ forbidden — with the clause-level
  caveat and the three call-site guards spelled out in the moduledoc. NOTE this
  function has no callers in `cloud/lib`: it is the policy table, and the gates
  read it through `team_admin?/2`, `team_owner?/2`, `role/2` and `can_grant?/3`.
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
