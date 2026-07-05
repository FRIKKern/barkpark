defmodule Barkpark.Tenancy.Auth do
  @moduledoc """
  Authorization primitives for the hard Workspace tenant boundary.

  A principal is bound to a Workspace by a `Barkpark.Tenancy.Membership` row.
  There are TWO kinds of principal, discriminated by the membership's
  `principal_type` column, and BOTH flow through the same `authorize/3`
  chokepoint:

    * **API token** (`principal_type: "api_token"`) — a token bound to a
      workspace. Authorization combines membership AND the token's
      `permissions` array (`:read`/`:write`/`:admin`).
    * **User** (`principal_type: "user"`) — a logged-in account (core-auth:
      accounts/sessions/MFA, and the principal that SSO/SCIM mint). A user
      carries no `permissions` array; its GRANT is its membership ROLE, so
      authorization combines membership AND the role.

  `authorize/3` is the single entry point the router and controllers call.
  It is total: any non-member, unknown action, or unrecognised principal is
  denied. Cross-tenant isolation is guaranteed by the membership lookup being
  keyed on `(principal_id, workspace_id, principal_type)` — a principal with
  no membership row in a workspace can never be authorized there.

  Action → satisfying grant:

    * API token permission strings:
      * `:read`  ← "read", "admin", "public-read"
      * `:write` ← "write", "admin"
      * `:admin` ← "admin"
    * User membership roles:
      * `:read`  ← "member", "admin", "owner"
      * `:write` ← "member", "admin", "owner"
      * `:admin` ← "admin", "owner"
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.{Membership, Role, RolePermission}

  @type action :: :read | :write | :admin
  @type principal :: ApiToken.t() | User.t() | binary()

  # Which permission strings satisfy each action (API-token principals).
  @read_perms ~w(read admin public-read)
  @write_perms ~w(write admin)
  @admin_perms ~w(admin)

  # Compiled-in action sets for the built-in USER roles — the SOURCE OF TRUTH
  # for byte-identity AND the fail-safe when no DB `role_permissions` row exists.
  # MUST equal the pre-data-driven semantics: read/write ← owner/admin/member,
  # admin ← owner/admin. Because enforcement falls back to this map, a fresh /
  # unseeded DB (or a lost row) can NEVER silently lock out a built-in role.
  @builtin_role_actions %{
    "owner" => ~w(read write admin),
    "admin" => ~w(read write admin),
    "member" => ~w(read write)
  }

  # Default role for a NEW membership when no explicit role is passed. A token
  # ADDED to a workspace it did not create is a `member` — write content, but
  # NOT admin — REGARDLESS of the token's global permissions[]. The role is the
  # GRANT, not a reflection of the token's global perms. The two legitimate
  # exceptions pass an explicit role: the workspace CREATOR ("owner", via
  # `Tenancy.create_workspace_with_owner/2`) and a token's OWN home-workspace
  # binding at mint-time (the perms-derived role, via `Auth.create_token/5`).
  @default_role "member"

  @doc """
  Insert a Membership binding a principal (API token) to a workspace.

  `principal_id` is the token id (a binary_id). `role` must be one of
  `Barkpark.Tenancy.Membership.roles/0`. When omitted it DEFAULTS to
  `"member"` — the core of the per-membership authz model (barkpark-23yi): a
  token added to a workspace gets `member` (write content only), independent of
  its global permissions. Callers that legitimately grant a higher role (the
  workspace creator → `owner`; a token's home-workspace mint binding → its
  perms-derived role) pass `role` EXPLICITLY. Returns the inserted membership
  or a changeset error (e.g. the principal is already a member of the workspace).
  """
  @spec create_membership(binary(), binary(), String.t(), String.t()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def create_membership(
        workspace_id,
        principal_id,
        role \\ @default_role,
        principal_type \\ "api_token"
      )
      when is_binary(workspace_id) and is_binary(principal_id) and is_binary(role) do
    %Membership{}
    |> Membership.changeset(
      %{
        workspace_id: workspace_id,
        principal_id: principal_id,
        role: role,
        principal_type: principal_type
      },
      valid_role_names(workspace_id)
    )
    |> Repo.insert()
  end

  # The role names accepted for a membership in this workspace: the built-ins
  # (owner/admin/member) plus any custom roles defined for the workspace (or
  # global custom roles). A defined custom role is accepted; a typo'd or
  # nonexistent role is still rejected by the changeset.
  defp valid_role_names(workspace_id) do
    custom =
      Repo.all(
        from r in Role,
          where: r.workspace_id == ^workspace_id or is_nil(r.workspace_id),
          select: r.name
      )

    Enum.uniq(Membership.roles() ++ custom)
  end

  @doc """
  Fetch the Membership for a token (or principal id) in a workspace, or nil.
  Accepts either an `%ApiToken{}` struct or a raw principal id binary.
  """
  @spec membership(principal(), binary()) :: Membership.t() | nil
  def membership(%ApiToken{id: principal_id}, workspace_id),
    do: membership(principal_id, workspace_id)

  # A User principal resolves to a `principal_type: "user"` membership row.
  # Kept SEPARATE from the raw-binary clause below (which defaults to
  # "api_token") so a user id can never accidentally match a token's grant —
  # the principal_type discriminator IS the cross-tenant/cross-kind isolation.
  def membership(%User{id: principal_id}, workspace_id)
      when is_binary(principal_id) and is_binary(workspace_id) do
    Repo.one(
      from m in Membership,
        where:
          m.principal_id == ^principal_id and
            m.workspace_id == ^workspace_id and
            m.principal_type == "user"
    )
  end

  def membership(principal_id, workspace_id)
      when is_binary(principal_id) and is_binary(workspace_id) do
    Repo.one(
      from m in Membership,
        where:
          m.principal_id == ^principal_id and
            m.workspace_id == ^workspace_id and
            m.principal_type == "api_token"
    )
  end

  @doc "True when the token (or principal id) is a member of the workspace."
  @spec member?(principal(), binary()) :: boolean()
  def member?(token_or_principal_id, workspace_id) do
    not is_nil(membership(token_or_principal_id, workspace_id))
  end

  @doc """
  Authorize `token` to perform `action` in `workspace_id`.

  Returns `:ok` when the token is a member of the workspace AND its
  `permissions` satisfy the action; `{:error, :forbidden}` otherwise.

  This is the function the router and controllers call. It is intentionally
  total — any unknown action or a non-member returns `{:error, :forbidden}`
  rather than raising.
  """
  @spec authorize(principal(), binary(), action()) :: :ok | {:error, :forbidden}
  def authorize(%ApiToken{} = token, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    if member?(token, workspace_id) and permits?(token, action) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  # User principal: the GRANT is the membership ROLE (users carry no
  # permissions[] array). A non-member is denied; a member is allowed when its
  # role satisfies the action. Same chokepoint, same total contract as tokens.
  def authorize(%User{} = user, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    case membership(user, workspace_id) do
      %Membership{role: role} ->
        if role_permits?(role, workspace_id, action), do: :ok, else: {:error, :forbidden}

      nil ->
        {:error, :forbidden}
    end
  end

  def authorize(_token, _workspace_id, _action), do: {:error, :forbidden}

  @doc """
  True when the membership `role` grants `action` in `workspace_id`, for USER
  principals. The grant is data-driven — a role's action set comes from
  `role_permissions` (`Barkpark.Tenancy.Role`) — with the compiled-in
  `@builtin_role_actions` as the fail-safe for the built-in roles, so
  enforcement never DEPENDS on a seed row and a missing row can't cause a
  silent lockout. A built-in name always resolves as built-in (a tenant can't
  redefine `admin` to escalate); a custom role resolves from its DB rows.
  """
  @spec role_permits?(String.t(), binary(), action()) :: boolean()
  def role_permits?(role, workspace_id, action)
      when is_binary(role) and is_binary(workspace_id) and action in [:read, :write, :admin] do
    Atom.to_string(action) in granted_actions(role, workspace_id)
  end

  def role_permits?(_role, _workspace_id, _action), do: false

  # Resolution: a built-in name ALWAYS resolves from the compiled-in map — the
  # DB row for a built-in is purely for Stage-B CRUD visibility and is IGNORED
  # for enforcement, so a tenant can never redefine `admin`/`member` (via a
  # workspace- or global-scoped row of the same name) to escalate OR to weaken
  # the fail-safe. A custom name resolves purely from its DB rows.
  defp granted_actions(role, workspace_id) do
    case Map.get(@builtin_role_actions, role) do
      nil -> db_actions(role, workspace_id)
      builtin -> builtin
    end
  end

  defp db_actions(role, workspace_id) do
    Repo.all(
      from rp in RolePermission,
        join: r in Role,
        on: rp.role_id == r.id,
        where:
          r.name == ^role and
            (r.workspace_id == ^workspace_id or is_nil(r.workspace_id)),
        select: rp.action
    )
  end

  @doc """
  True when the token's permissions satisfy `action`, ignoring membership.
  Exposed so the write-gate plug can check permission without a workspace.
  """
  # The `when is_list(perms)` guard keeps these clauses total: a token whose
  # `permissions` is nil (e.g. a NULL DB column) falls THROUGH to the catch-all
  # and is denied, rather than raising `ArgumentError` on `&1 in nil`. nil
  # permissions → deny (false), never raise.
  @spec permits?(ApiToken.t(), action()) :: boolean()
  def permits?(%ApiToken{permissions: perms}, :read) when is_list(perms),
    do: Enum.any?(@read_perms, &(&1 in perms))

  def permits?(%ApiToken{permissions: perms}, :write) when is_list(perms),
    do: Enum.any?(@write_perms, &(&1 in perms))

  def permits?(%ApiToken{permissions: perms}, :admin) when is_list(perms),
    do: Enum.any?(@admin_perms, &(&1 in perms))

  def permits?(_token, _action), do: false

  @doc """
  Derive the workspace role from a permissions array: `"admin"` when the
  permissions include "admin", otherwise `"member"`.

  SCOPE: this is the role for a token's OWN home workspace ONLY — the workspace
  the token is minted into (`Auth.create_token/5`). It is a legitimate
  perms-derived role because the token's home workspace is its own. It is NOT
  used when ADDING a token to ANOTHER workspace — that path defaults to
  `member` (see `create_membership/4`). This is the fix for the cross-tenant
  admin bypass (barkpark-23yi / barkpark-fsko): a global-admin token added to
  workspace B must NOT become admin of B.
  """
  @spec role_for_permissions([String.t()]) :: String.t()
  def role_for_permissions(permissions) when is_list(permissions) do
    if "admin" in permissions, do: "admin", else: "member"
  end

  # Roles that confer workspace-admin authority on a scoped surface.
  @admin_roles ~w(owner admin)

  @doc """
  The token's MEMBERSHIP ROLE in `workspace_id`, or nil when it is not a member.
  This reads the GRANT (the `workspace_memberships.role` column), NOT the
  token's global permissions[]. Accepts a token struct or a raw principal id.
  """
  @spec membership_role(principal(), binary()) :: String.t() | nil
  def membership_role(token_or_principal_id, workspace_id) do
    case membership(token_or_principal_id, workspace_id) do
      %Membership{role: role} -> role
      nil -> nil
    end
  end

  @doc """
  True when the token's membership ROLE in `workspace_id` confers admin
  authority (`owner` or `admin`). This is the per-membership admin gate: a
  `member` of B — even one holding global `admin` perms — is NOT a workspace
  admin of B. A non-member is never an admin.
  """
  @spec workspace_admin?(principal(), binary()) :: boolean()
  def workspace_admin?(token_or_principal_id, workspace_id) do
    membership_role(token_or_principal_id, workspace_id) in @admin_roles
  end
end
