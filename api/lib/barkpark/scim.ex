defmodule Barkpark.Scim do
  @moduledoc """
  SCIM 2.0 directory-sync for USER provisioning (era-w4-scim-users).

  An IdP authenticates to `/scim/v2/*` with a per-Organization bearer token
  (`Barkpark.Scim.Token`) and provisions/deprovisions users. A provisioned user
  becomes a member of the organization's workspaces; **deprovisioning revokes
  every session AND membership immediately** — the hard enterprise requirement
  (`revoke_all_user_sessions/1`). Every change emits an audit event.

  Org isolation: a token resolves to exactly one organization, and all
  operations are scoped to that org's workspaces — a token for org A can never
  read or mutate a user in org B.
  """
  import Ecto.Query, warn: false

  alias Barkpark.{Accounts, Audit, Repo, Tenancy}
  alias Barkpark.Accounts.User
  alias Barkpark.Scim.Token
  alias Barkpark.Tenancy.{Membership, Organization, Workspace}

  @provision_role "member"

  # ── Tokens ───────────────────────────────────────────────────────────────

  @doc "Mint a SCIM token for `organization_id`. Returns `{plaintext, token}`."
  @spec mint_token(binary(), String.t() | nil) :: {:ok, {binary(), Token.t()}} | {:error, term()}
  def mint_token(organization_id, label \\ nil) do
    plaintext = "scim_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))

    %Token{}
    |> Token.changeset(%{
      organization_id: organization_id,
      token_hash: Token.hash_token(plaintext),
      label: label
    })
    |> Repo.insert()
    |> case do
      {:ok, tok} -> {:ok, {plaintext, tok}}
      err -> err
    end
  end

  @doc "Resolve a raw SCIM bearer token to its Organization, or nil (revoked/unknown deny)."
  @spec resolve_org(binary()) :: Organization.t() | nil
  def resolve_org(raw) when is_binary(raw) do
    hash = Token.hash_token(raw)

    Repo.one(
      from t in Token,
        join: o in Organization,
        on: o.id == t.organization_id,
        where: t.token_hash == ^hash and is_nil(t.revoked_at),
        select: o
    )
  end

  def resolve_org(_), do: nil

  # ── Provision / deprovision ────────────────────────────────────────────────

  @doc """
  Provision a user into `org` from SCIM attrs (`userName` = email). Creates a
  confirmed User (unusable password — they sign in via SSO / magic-link) and a
  membership in every workspace of the org. Idempotent on email: an existing
  user is re-used and (re)attached. Emits a `user_provisioned` audit event.
  """
  @spec provision_user(Organization.t(), map()) :: {:ok, User.t()} | {:error, term()}
  def provision_user(%Organization{} = org, attrs) do
    email = attrs["userName"]

    with true <- is_binary(email) and email != "",
         {:ok, user} <- upsert_user(email) do
      attach_to_org(user, org)
      audit(org, user, "user_provisioned", %{"email" => email})
      {:ok, user}
    else
      false -> {:error, :missing_username}
      err -> err
    end
  end

  @doc """
  Deprovision `user` from `org`: revoke ALL sessions, drop every membership in
  the org's workspaces, and (when `hard: true`, the SCIM DELETE) remove the user
  row. Emits a `user_deprovisioned` audit event. Returns a summary.
  """
  @spec deprovision_user(Organization.t(), User.t(), keyword()) :: {:ok, map()}
  def deprovision_user(%Organization{} = org, %User{} = user, opts \\ []) do
    hard = Keyword.get(opts, :hard, false)
    ws_ids = org |> workspace_ids()

    Repo.transaction(fn ->
      Accounts.revoke_all_user_sessions(user)

      {dropped, _} =
        Repo.delete_all(
          from m in Membership,
            where:
              m.principal_type == "user" and m.principal_id == ^user.id and
                m.workspace_id in ^ws_ids
        )

      audit(org, user, "user_deprovisioned", %{"hard" => hard, "memberships_dropped" => dropped})

      if hard, do: Repo.delete!(user)

      %{memberships_dropped: dropped, hard: hard}
    end)
  end

  # ── Org-scoped reads ───────────────────────────────────────────────────────

  @doc "A user, only if they are a member of one of `org`'s workspaces; else nil."
  @spec get_org_user(Organization.t(), binary()) :: User.t() | nil
  def get_org_user(%Organization{} = org, user_id) when is_binary(user_id) do
    if member_of_org?(org, user_id), do: Accounts.get_user(user_id), else: nil
  end

  def get_org_user(_org, _), do: nil

  @doc "Users provisioned into `org` (members of its workspaces). Optional email filter."
  @spec list_org_users(Organization.t(), String.t() | nil) :: [User.t()]
  def list_org_users(%Organization{} = org, email_filter \\ nil) do
    ws_ids = workspace_ids(org)

    base =
      from u in User,
        join: m in Membership,
        on: m.principal_id == u.id and m.principal_type == "user",
        where: m.workspace_id in ^ws_ids,
        distinct: true

    query = if email_filter, do: from(u in base, where: u.email == ^email_filter), else: base
    Repo.all(query)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp upsert_user(email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        {:ok, user}

      _ ->
        # Unusable password — SCIM users authenticate via SSO / magic-link.
        random = Base.encode16(:crypto.strong_rand_bytes(32))

        case Accounts.register_user(%{email: email, password: random}) do
          {:ok, user} -> {:ok, Repo.update!(User.confirm_changeset(user))}
          err -> err
        end
    end
  end

  defp attach_to_org(user, org) do
    for ws_id <- workspace_ids(org) do
      # Idempotent: a duplicate membership hits the unique constraint → ignored.
      Tenancy.Auth.create_membership(ws_id, user.id, @provision_role, "user")
    end
  end

  defp workspace_ids(%Organization{id: id}) do
    Repo.all(from w in Workspace, where: w.organization_id == ^id, select: w.id)
  end

  defp member_of_org?(org, user_id) do
    ws_ids = workspace_ids(org)

    Repo.exists?(
      from m in Membership,
        where:
          m.principal_type == "user" and m.principal_id == ^user_id and
            m.workspace_id in ^ws_ids
    )
  end

  defp audit(org, user, action, metadata) do
    Audit.emit(%{
      category: "membership",
      action: action,
      subject: user.id,
      actor_type: "scim",
      metadata: Map.merge(%{"organization_id" => org.id}, metadata)
    })
  end
end
