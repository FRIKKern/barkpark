defmodule Barkpark.Sso do
  @moduledoc """
  Shared SSO helpers. `jit_provision/3` is just-in-time provisioning: on first
  SSO login, give the authenticated User a membership in the organization's
  workspaces (idempotent), so an SSO user gains access without a separate SCIM
  push. The role defaults to `member`; SCIM group→role sync (era-w4) refines it.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Accounts.User
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Workspace

  @default_role "member"

  @doc """
  Provision `user` into every workspace of `org_id` as `role`. Idempotent — an
  existing membership hits the unique constraint and is left as-is. Returns the
  number of workspaces targeted.
  """
  @spec jit_provision(binary(), User.t(), String.t()) :: non_neg_integer()
  def jit_provision(org_id, %User{id: uid}, role \\ @default_role) when is_binary(org_id) do
    ws_ids = Repo.all(from w in Workspace, where: w.organization_id == ^org_id, select: w.id)

    for ws_id <- ws_ids do
      Tenancy.Auth.create_membership(ws_id, uid, role, "user")
    end

    length(ws_ids)
  end
end
