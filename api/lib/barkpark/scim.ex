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
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Scim.{Group, Token}
  alias Barkpark.Tenancy.{Membership, Organization, Role, Workspace}

  @provision_role "member"

  # ── Tokens ───────────────────────────────────────────────────────────────

  @doc "Active SCIM tokens for an org (metadata only — never the secret)."
  @spec list_tokens(binary()) :: [Token.t()]
  def list_tokens(organization_id) when is_binary(organization_id) do
    Repo.all(
      from t in Token,
        where: t.organization_id == ^organization_id and is_nil(t.revoked_at),
        order_by: [desc: t.inserted_at]
    )
  end

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
      {:ok, tok} ->
        # Audit every mint (portal or API) — a token is a standing credential.
        Audit.emit(%{
          category: "token",
          action: "scim_token_minted",
          subject: tok.id,
          actor_type: "scim",
          metadata: %{"organization_id" => organization_id, "label" => label}
        })

        {:ok, {plaintext, tok}}

      err ->
        err
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
  Deprovision `user` from `org`: revoke ALL sessions, revoke every owner-bound
  Personal Access Token, drop every membership in the org's workspaces, and
  (when `hard: true`, the SCIM DELETE) remove the user row. Emits a
  `user_deprovisioned` audit event. Returns a summary.

  ## Why the PAT revoke lives INSIDE this transaction, BEFORE the hard-delete

  A killed session is not enough: a deprovisioned user who minted a PAT
  (`owner_user_id == user.id`) would otherwise keep a LIVE bearer even after
  their session dies — `Auth.verify_token/1` never reads `owner_user_id`, so a
  soft deprovision leaves the token resolving. We therefore stamp `revoked_at`
  on every live owner-bound token here.

  Sequencing is load-bearing: the `owner_user_id` FK is `on_delete: :nilify_all`,
  so once `Repo.delete!(user)` runs the column is nilified and NO key remains to
  find the tokens. The revoke MUST precede the hard-delete. Share-edit tokens
  are scope-keyed (`share_scope`, `owner_user_id` NULL) and are deliberately
  untouched — they are revoked with their share, not their minter.
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

      # BEFORE the hard-delete nilifies owner_user_id (FK on_delete: :nilify_all).
      tokens_revoked = revoke_owner_tokens(user)

      audit(org, user, "user_deprovisioned", %{
        "hard" => hard,
        "memberships_dropped" => dropped,
        "tokens_revoked" => tokens_revoked
      })

      if hard, do: Repo.delete!(user)

      %{memberships_dropped: dropped, tokens_revoked: tokens_revoked, hard: hard}
    end)
  end

  # Stamp `revoked_at` on every LIVE api_token owned by this user, so
  # `Auth.verify_token/1` rejects it immediately. Owner-bound PATs ONLY: share
  # tokens (`share_scope` set, `owner_user_id` NULL) never match this WHERE and
  # are left alone. Emits a `token/user_tokens_revoked` audit event when any
  # token was killed (a standing credential lifecycle event).
  defp revoke_owner_tokens(%User{id: user_id} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {n, _} =
      Repo.update_all(
        from(t in ApiToken,
          where: t.owner_user_id == ^user_id and is_nil(t.revoked_at)
        ),
        set: [revoked_at: now]
      )

    if n > 0 do
      Audit.emit(%{
        category: "token",
        action: "user_tokens_revoked",
        subject: user.id,
        actor_type: "scim",
        metadata: %{"tokens_revoked" => n}
      })
    end

    n
  end

  # ── Org-scoped reads ───────────────────────────────────────────────────────

  @doc "A user, only if they are a member of one of `org`'s workspaces; else nil."
  @spec get_org_user(Organization.t(), binary()) :: User.t() | nil
  def get_org_user(%Organization{} = org, user_id) when is_binary(user_id) do
    # #672 class: `user_id` binds to `:binary_id` columns (Membership.principal_id,
    # User.id). A non-UUID path param would raise Ecto.CastError → 500; guard the
    # cast so a malformed id folds into the existing not_found (`nil`) branch → 404.
    case Repo.uuid_or_nil(user_id) do
      nil -> nil
      uuid -> if member_of_org?(org, uuid), do: Accounts.get_user(uuid), else: nil
    end
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

  # ── Groups (era-w4-scim-groups) ────────────────────────────────────────────

  @doc """
  Create a SCIM Group in `org` that maps to a Barkpark role. `role_name` must be
  a known role — a built-in (owner/admin/member) or a custom role defined for
  the org (or globally). Returns `{:error, :unknown_role}` otherwise.
  """
  @spec create_group(Organization.t(), map()) ::
          {:ok, Group.t()} | {:error, term()}
  def create_group(%Organization{} = org, attrs) do
    role_name = attrs["role"] || attrs["displayName"]

    cond do
      not (is_binary(attrs["displayName"]) and attrs["displayName"] != "") ->
        {:error, :missing_display_name}

      not known_role?(org, role_name) ->
        {:error, :unknown_role}

      true ->
        %Group{}
        |> Group.changeset(%{
          organization_id: org.id,
          display_name: attrs["displayName"],
          role_name: role_name,
          external_id: attrs["externalId"]
        })
        |> Repo.insert()
        |> case do
          {:ok, group} = ok ->
            audit_group_lifecycle(org, group, "scim_group_created")
            ok

          err ->
            err
        end
    end
  end

  @doc "A group in `org` by id, or nil."
  @spec get_org_group(Organization.t(), binary()) :: Group.t() | nil
  def get_org_group(%Organization{id: oid}, id) when is_binary(id) do
    # #672 class: `id` binds to Group's `:binary_id` PK. A non-UUID path param
    # would raise Ecto.CastError → 500; guard the cast so a malformed id folds
    # into the existing `nil` branch → SCIM 404.
    case Repo.uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.one(from g in Group, where: g.id == ^uuid and g.organization_id == ^oid)
    end
  end

  def get_org_group(_org, _), do: nil

  @doc "Groups in `org`."
  @spec list_org_groups(Organization.t()) :: [Group.t()]
  def list_org_groups(%Organization{id: oid}),
    do:
      Repo.all(from g in Group, where: g.organization_id == ^oid, order_by: [asc: g.display_name])

  @doc """
  Delete `group` from `org`. Tenancy-scoped: the delete is filtered by
  `organization_id`, so a token for org A can never remove a group in org B.
  Returns `{:ok, deleted_count}` (0 when the group is not in this org).
  """
  @spec delete_group(Organization.t(), Group.t()) :: {:ok, non_neg_integer()}
  def delete_group(%Organization{id: oid} = org, %Group{} = group) do
    {n, _} =
      Repo.delete_all(from g in Group, where: g.id == ^group.id and g.organization_id == ^oid)

    # Only audit a delete that actually removed the org's own group (n > 0) — a
    # cross-org delete attempt matches nothing and is a no-op, not a lifecycle event.
    if n > 0, do: audit_group_lifecycle(org, group, "scim_group_deleted")

    {:ok, n}
  end

  @doc """
  Add `user_id` to `group`: set that user's membership role (in the org's
  workspaces) to the group's mapped role. No-op if the user isn't provisioned
  into the org. Audited.
  """
  @spec add_group_member(Organization.t(), Group.t(), binary()) :: {:ok, non_neg_integer()}
  def add_group_member(%Organization{} = org, %Group{} = group, user_id) do
    n = set_member_role(org, user_id, group.role_name)
    audit_group(org, user_id, group, "group_member_added", group.role_name)
    {:ok, n}
  end

  @doc """
  Remove `user_id` from `group`: revert that user's membership role (in the
  org's workspaces) to the default `member`, revoking the mapped grant. Audited.
  """
  @spec remove_group_member(Organization.t(), Group.t(), binary()) :: {:ok, non_neg_integer()}
  def remove_group_member(%Organization{} = org, %Group{} = group, user_id) do
    n = set_member_role(org, user_id, @provision_role)
    audit_group(org, user_id, group, "group_member_removed", @provision_role)
    {:ok, n}
  end

  # Set the user's role on every membership it holds in the org's workspaces.
  defp set_member_role(org, user_id, role_name) do
    ws_ids = workspace_ids(org)

    {n, _} =
      Repo.update_all(
        from(m in Membership,
          where:
            m.principal_type == "user" and m.principal_id == ^user_id and
              m.workspace_id in ^ws_ids
        ),
        set: [role: role_name, updated_at: DateTime.utc_now()]
      )

    n
  end

  # A role name is known if it's a built-in or a Role row that's global or
  # scoped to one of the org's workspaces (roles are workspace-scoped).
  defp known_role?(org, role_name) when is_binary(role_name) do
    ws_ids = workspace_ids(org)

    role_name in Membership.roles() or
      Repo.exists?(
        from r in Role,
          where: r.name == ^role_name and (is_nil(r.workspace_id) or r.workspace_id in ^ws_ids)
      )
  end

  defp known_role?(_org, _), do: false

  # Group create/delete lifecycle audit (membership category — a SCIM group maps
  # to a Barkpark role grant). Subject is the group id; metadata names the org,
  # display name and mapped role for the audit reader.
  defp audit_group_lifecycle(org, %Group{} = group, action) do
    Audit.emit(%{
      category: "membership",
      action: action,
      subject: group.id,
      actor_type: "scim",
      metadata: %{
        "organization_id" => org.id,
        "group" => group.display_name,
        "role" => group.role_name
      }
    })
  end

  defp audit_group(org, user_id, group, action, role_name) do
    Audit.emit(%{
      category: "membership",
      action: action,
      subject: user_id,
      actor_type: "scim",
      metadata: %{
        "organization_id" => org.id,
        "group" => group.display_name,
        "role" => role_name
      }
    })
  end
end
