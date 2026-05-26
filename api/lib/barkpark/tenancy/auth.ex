defmodule Barkpark.Tenancy.Auth do
  @moduledoc """
  Authorization primitives for the hard Workspace tenant boundary.

  The principal is the API TOKEN — there is NO users/accounts model. A token
  is bound to a Workspace by a `Barkpark.Tenancy.Membership` row whose
  `principal_id` is the token id. Authorization combines two facts:

    1. membership — the token must be a member of the target workspace, and
    2. permission — the token's `permissions` array must satisfy the action.

  `authorize/3` is the single entry point the router and controllers call.
  The read-path workspace check (query_controller) and the route-level
  workspace resolution (`/w/:workspace`) are sibling tasks; they call
  `authorize(token, workspace_id, :read | :write | :admin)` — it is ready for
  them now.

  Action → satisfying permission strings:

    * `:read`  ← "read", "admin", "public-read"
    * `:write` ← "write", "admin"
    * `:admin` ← "admin"
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Membership

  @type action :: :read | :write | :admin
  @type principal :: ApiToken.t() | binary()

  # Which permission strings satisfy each action.
  @read_perms ~w(read admin public-read)
  @write_perms ~w(write admin)
  @admin_perms ~w(admin)

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
  def create_membership(workspace_id, principal_id, role \\ @default_role, principal_type \\ "api_token")
      when is_binary(workspace_id) and is_binary(principal_id) and is_binary(role) do
    %Membership{}
    |> Membership.changeset(%{
      workspace_id: workspace_id,
      principal_id: principal_id,
      role: role,
      principal_type: principal_type
    })
    |> Repo.insert()
  end

  @doc """
  Fetch the Membership for a token (or principal id) in a workspace, or nil.
  Accepts either an `%ApiToken{}` struct or a raw principal id binary.
  """
  @spec membership(principal(), binary()) :: Membership.t() | nil
  def membership(%ApiToken{id: principal_id}, workspace_id),
    do: membership(principal_id, workspace_id)

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
  @spec authorize(ApiToken.t(), binary(), action()) :: :ok | {:error, :forbidden}
  def authorize(%ApiToken{} = token, workspace_id, action)
      when is_binary(workspace_id) and action in [:read, :write, :admin] do
    if member?(token, workspace_id) and permits?(token, action) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  def authorize(_token, _workspace_id, _action), do: {:error, :forbidden}

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
