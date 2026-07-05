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

  # Built-in rank for picking ONE role when several mapped groups match.
  # Custom roles rank below the built-ins and tie-break alphabetically, so the
  # outcome is deterministic whatever order the IdP lists groups in.
  @builtin_rank %{"owner" => 3, "admin" => 2, "member" => 1}

  @doc """
  Resolve the role an OIDC connection's group→role mappings grant for `claims`
  (era-w7). Reads the connection's `groups_claim` (string or list), intersects
  with the ADMIN-CONFIGURED `group_role_mappings`, and returns the
  highest-ranked mapped role — or nil when the claim is absent, empty, or
  matches no mapping. Claims can only SELECT among configured mappings: an
  unmapped group name grants nothing, so there is no escalation path from
  tenant-supplied tokens.
  """
  @spec resolve_group_role(struct(), map()) :: String.t() | nil
  def resolve_group_role(%{groups_claim: claim, group_role_mappings: mappings}, claims)
      when is_map(mappings) and map_size(mappings) > 0 do
    groups =
      case Map.get(claims || %{}, claim || "groups") do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        one when is_binary(one) -> [one]
        _ -> []
      end

    groups
    |> Enum.flat_map(fn g ->
      case Map.get(mappings, g) do
        role when is_binary(role) -> [role]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      roles -> Enum.max_by(roles, fn r -> {Map.get(@builtin_rank, r, 0), inverse_alpha(r)} end)
    end
  end

  def resolve_group_role(_connection, _claims), do: nil

  # max_by prefers the LARGER tuple; for equal ranks we want the alphabetically
  # FIRST custom role, so compare on the negated codepoints.
  defp inverse_alpha(s), do: s |> String.to_charlist() |> Enum.map(&(-&1))

  @doc """
  Authoritative role sync for group-mapped logins: set `role` on the user's
  EXISTING memberships across the org's workspaces (mirrors SCIM group-sync
  semantics — the IdP's current groups win, including downgrades). Returns the
  number of memberships updated. Only called when a mapping actually resolved;
  an absent groups claim never touches existing roles.
  """
  @spec set_org_member_role(binary(), binary(), String.t()) :: non_neg_integer()
  def set_org_member_role(org_id, user_id, role)
      when is_binary(org_id) and is_binary(user_id) and is_binary(role) do
    ws_ids = Repo.all(from w in Workspace, where: w.organization_id == ^org_id, select: w.id)

    {n, _} =
      Repo.update_all(
        from(m in Tenancy.Membership,
          where:
            m.principal_type == "user" and m.principal_id == ^user_id and
              m.workspace_id in ^ws_ids and m.role != ^role
        ),
        set: [role: role, updated_at: DateTime.utc_now()]
      )

    n
  end
end
