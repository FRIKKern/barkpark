defmodule Barkpark.Sso do
  @moduledoc """
  Shared SSO helpers. `jit_provision/3` is just-in-time provisioning: on first
  SSO login, give the authenticated User a membership in the organization's
  workspaces (idempotent), so an SSO user gains access without a separate SCIM
  push. The role defaults to `member`; SCIM group→role sync (era-w4) refines it.
  """
  import Ecto.Query, warn: false

  alias Barkpark.{Accounts, Repo}
  alias Barkpark.Accounts.User
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Workspace

  @default_role "member"

  @doc """
  Record an SSO/social login on the audit trail. Emits an `auth`/`sso_login`
  event with the provider and (optional) organization. Called from every SSO
  callback so "who signed in via which IdP, when" is on the tamper-evident log.
  """
  @spec record_login(User.t(), String.t(), binary() | nil) :: :ok
  def record_login(%User{id: uid}, provider, org_id \\ nil) do
    Barkpark.Audit.emit(%{
      category: "auth",
      action: "sso_login",
      subject: uid,
      actor_type: "user",
      actor_id: uid,
      metadata: %{"provider" => provider, "organization_id" => org_id}
    })

    :ok
  end

  @doc """
  Find-or-create the SSO-authenticated User by `email`. New accounts get an
  unusable local password (they sign in via the IdP) and are confirmed (the IdP
  vouched for the identity). Shared by the OIDC / SAML flows.
  """
  @spec find_or_create_user(String.t()) :: User.t()
  def find_or_create_user(email) when is_binary(email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        user

      _ ->
        random = Base.encode16(:crypto.strong_rand_bytes(32))
        {:ok, user} = Accounts.register_user(%{email: email, password: random})
        Repo.update!(User.confirm_changeset(user))
    end
  end

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
