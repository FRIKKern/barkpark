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

  @doc """
  Insert a Membership binding a principal (API token) to a workspace.

  `principal_id` is the token id (a binary_id). `role` must be one of
  `Barkpark.Tenancy.Membership.roles/0`. Returns the inserted membership or a
  changeset error (e.g. the principal is already a member of the workspace).
  """
  @spec create_membership(binary(), binary(), String.t(), String.t()) ::
          {:ok, Membership.t()} | {:error, Ecto.Changeset.t()}
  def create_membership(workspace_id, principal_id, role, principal_type \\ "api_token")
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
  @spec permits?(ApiToken.t(), action()) :: boolean()
  def permits?(%ApiToken{permissions: perms}, :read), do: Enum.any?(@read_perms, &(&1 in perms))
  def permits?(%ApiToken{permissions: perms}, :write), do: Enum.any?(@write_perms, &(&1 in perms))
  def permits?(%ApiToken{permissions: perms}, :admin), do: Enum.any?(@admin_perms, &(&1 in perms))
  def permits?(_token, _action), do: false

  @doc """
  Derive the workspace role from a permissions array: `"admin"` when the
  permissions include "admin", otherwise `"member"`. Used when binding a
  freshly-minted token to its workspace.
  """
  @spec role_for_permissions([String.t()]) :: String.t()
  def role_for_permissions(permissions) when is_list(permissions) do
    if "admin" in permissions, do: "admin", else: "member"
  end
end
