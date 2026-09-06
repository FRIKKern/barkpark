defmodule Barkpark.Tenancy.Members do
  @moduledoc """
  The workspace MEMBER ADMINISTRATION surface: read the roster, seat a human,
  change a seat's role, remove a seat.

  ## Why this module exists

  Every primitive underneath it already existed — `Membership` (the table with
  its role vocabulary), `Auth.create_membership/4`, `Auth.workspace_admin?/2`,
  the custom-role widening — but nothing ever *exposed* them. The practical
  consequence, found by a real migration run: the OWNER of an instance could
  not seat their own user account in a workspace their token had created.
  `bp access grant` refuses (its no-escalation gate demands the grantor already
  hold the capability IN that workspace), and a claimed grant never writes a
  membership row at all, so it can never produce Studio visibility. The only
  path that worked was an undocumented side effect of the mobile/cloud
  app-token mint. This module is that missing surface, stated once.

  ## Scope of the roster

  A workspace seat is a `Membership` row, and there are two principal kinds, so
  the roster lists BOTH: human `user` seats and `api_token` seats. That is
  deliberate — "who can reach this workspace" is not answerable by looking at
  humans alone, and a token roster that lives somewhere else is a roster nobody
  reads. Token rows carry their label, permissions and revoked state; a token's
  SECRET is never touched here (only `token_hash` is persisted, and it is never
  selected).

  Airdrop grants are NOT seats and are deliberately absent: a grant is a
  time-boxed capability overlay resolved per request (`Barkpark.Access`), it
  writes no membership row, and folding it in here would blur "who is a member"
  with "who currently holds a link". `bp access ls` is its roster.

  ## The two rails that make this safe to expose

  1. **Last-owner protection.** `owner` is the only role that cannot be locked
     out of its own workspace, so removing or demoting the LAST owner is
     refused with `{:error, :last_owner}`. Without this rail an admin surface
     is also an admin-lockout surface: one `member-rm` on the wrong row and the
     workspace has nobody who can ever administer it again (there is no
     recovery path short of DB access). The check counts owners in the
     workspace, not seats — a workspace with two owners can lose either one.

  2. **Explicit principal kind.** A bare UUID says nothing about whether it
     names a user or a token, and reading it as the wrong kind is exactly the
     hazard `Tenancy.Auth` documents at length. Callers here pass a
     `%{type: kind, id: id}` resolved by `resolve_principal/2`, which turns an
     e-mail into a `:user` and requires the kind to be stated for a raw id.

  Every mutation returns `{:ok, _}` or a tagged `{:error, reason}` — no raises
  on ordinary denial, matching the fail-closed posture of `Tenancy.Auth`.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Sso
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @owner_role "owner"

  @typedoc """
  A resolved principal reference: the kind is STATED, never inferred from the
  shape of the id.
  """
  @type principal_ref :: %{type: :user | :api_token, id: binary()}

  @typedoc "One roster row — a seat, with the identity that holds it."
  @type member_row :: %{
          principal_type: String.t(),
          principal_id: binary(),
          role: String.t(),
          identity: String.t() | nil,
          permissions: [String.t()] | nil,
          revoked: boolean() | nil,
          inserted_at: DateTime.t()
        }

  @doc """
  The workspace roster: every seat, both kinds, with the identity behind it.

  Users resolve to their e-mail, tokens to their label (never their secret).
  An identity that no longer exists — a deleted user, a purged token — still
  yields its row with `identity: nil` rather than being dropped: a seat whose
  holder vanished is precisely the kind of thing an owner needs to SEE in order
  to clean it up, and silently hiding it would make the roster lie about who
  can reach the workspace.

  Ordered owners first, then admins, then members, then custom roles — the
  order an administrator reads — and within a role band by `inserted_at`, then
  `id`. That ORDER IS TOTAL AND COMPUTED IN THE DATABASE, which is what makes
  `:limit`/`:offset` paging safe: a page boundary lands in the same place on
  every request, so page 2 neither repeats nor skips a row from page 1. The
  secondary key used to be the identity, downcased — an Elixir-side sort over
  values that live in two OTHER tables (users, api_tokens), so it could only
  ever be applied AFTER loading the whole roster. Keeping it would have meant
  keeping the unbounded read this function exists to bound.

  `opts`: `:limit` (a page size; no limit means every row, which is what the
  in-process callers that are not the HTTP surface still want) and `:offset`.
  Pair it with `count_members/1` for the grand total.
  """
  @spec list_members(binary(), keyword()) :: [member_row()]
  def list_members(workspace_id, opts \\ [])

  def list_members(workspace_id, opts) when is_binary(workspace_id) and is_list(opts) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        []

      uuid ->
        memberships = uuid |> roster_query() |> paged(opts) |> Repo.all()

        users = identities(memberships, "user")
        tokens = identities(memberships, "api_token")

        Enum.map(memberships, &decorate(&1, users, tokens))
    end
  end

  def list_members(_, _), do: []

  @doc """
  How many seats the workspace has — the grand total behind a `list_members/2`
  page, so a client can tell a short page from the last one.
  """
  @spec count_members(binary()) :: non_neg_integer()
  def count_members(workspace_id) when is_binary(workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil -> 0
      uuid -> Repo.aggregate(from(m in Membership, where: m.workspace_id == ^uuid), :count)
    end
  end

  def count_members(_), do: 0

  # Owners, then admins, then members, then custom roles — the ranking the
  # Elixir-side `role_rank/1` used to apply, now expressed in SQL so it
  # survives a LIMIT instead of needing the whole roster — tie-broken by
  # inserted_at
  # and then the row id — which is unique, so the order is TOTAL. A partial
  # order here would make offset paging drop and duplicate rows silently.
  defp roster_query(workspace_uuid) do
    from(m in Membership,
      where: m.workspace_id == ^workspace_uuid,
      order_by: [
        asc:
          fragment(
            "CASE ? WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 WHEN 'member' THEN 2 ELSE 3 END",
            m.role
          ),
        asc: m.inserted_at,
        asc: m.id
      ]
    )
  end

  @doc """
  Seat a HUMAN in the workspace by e-mail.

  The account is resolved through `Sso.find_or_create_user/1` — the same
  just-in-time path SSO, SCIM and the cloud app-token bridge already use — so
  seating somebody who has never signed in works, and seating somebody who has
  reuses their account. JIT creation is a real side effect: the account is
  auto-confirmed with a random password and NO e-mail is sent, so the invitee
  must sign in through a channel that does not need that password (SSO, magic
  link, or a reset). Callers that need a notification must send it themselves;
  this function does not pretend to be an invitation system.

  Refuses `{:error, :already_member}` rather than silently re-roling an
  existing seat — changing a role is `update_role/3`, and an "add" that quietly
  overwrote a role would be a privilege change disguised as a no-op.
  """
  @spec add_user_member(binary(), String.t(), String.t()) ::
          {:ok, member_row()} | {:error, atom() | Ecto.Changeset.t()}
  def add_user_member(workspace_id, email, role)
      when is_binary(workspace_id) and is_binary(email) and is_binary(role) do
    with {:ok, email} <- normalize_email(email),
         %User{} = user <- Sso.find_or_create_user(email),
         nil <- TenancyAuth.membership(user.id, workspace_id, :user) do
      case TenancyAuth.create_membership(workspace_id, user.id, role, "user") do
        {:ok, membership} ->
          {:ok, decorate(membership, %{user.id => email}, %{})}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
      %Membership{} -> {:error, :already_member}
      _ -> {:error, :user_unavailable}
    end
  end

  @doc """
  Change an existing seat's role.

  Refuses to demote the last owner (`{:error, :last_owner}`) and to touch a
  seat that does not exist (`{:error, :not_found}`). The role itself is
  validated by the membership changeset, which accepts the built-ins plus this
  workspace's custom roles — so a typo is a changeset error, not a silent
  no-role seat.
  """
  @spec update_role(binary(), principal_ref(), String.t()) ::
          {:ok, member_row()} | {:error, atom() | Ecto.Changeset.t()}
  def update_role(workspace_id, %{type: type, id: principal_id}, role)
      when is_binary(workspace_id) and is_binary(role) do
    case TenancyAuth.membership(principal_id, workspace_id, type) do
      nil ->
        {:error, :not_found}

      %Membership{} = membership ->
        if demotes_last_owner?(membership, role) do
          {:error, :last_owner}
        else
          membership
          |> Membership.changeset(%{role: role}, valid_role_names(workspace_id))
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, decorate_one(updated)}
            {:error, changeset} -> {:error, changeset}
          end
        end
    end
  end

  @doc """
  Remove a seat.

  Refuses to remove the last owner (`{:error, :last_owner}`). Removing a token
  seat revokes nothing — the token keeps existing and simply loses its
  membership in THIS workspace, which is the correct blast radius for a
  per-workspace roster operation. Killing the credential itself is
  `Barkpark.Auth.revoke_token/1`.
  """
  @spec remove_member(binary(), principal_ref()) ::
          {:ok, member_row()} | {:error, atom()}
  def remove_member(workspace_id, %{type: type, id: principal_id})
      when is_binary(workspace_id) do
    case TenancyAuth.membership(principal_id, workspace_id, type) do
      nil ->
        {:error, :not_found}

      %Membership{role: @owner_role} = membership ->
        if last_owner?(membership) do
          {:error, :last_owner}
        else
          delete_membership(membership)
        end

      %Membership{} = membership ->
        delete_membership(membership)
    end
  end

  @doc """
  Resolve a caller-supplied principal reference.

  Accepts an e-mail (resolved to an EXISTING user — never JIT-created here;
  removing or re-roling somebody should not be able to conjure the account it
  then operates on) or a raw UUID whose kind is stated by `default_type`.
  Returns `{:error, :unknown_principal}` when an e-mail names nobody, and
  `{:error, :invalid_principal}` for a reference that is neither.
  """
  @spec resolve_principal(String.t(), :user | :api_token) ::
          {:ok, principal_ref()} | {:error, atom()}
  def resolve_principal(ref, default_type \\ :user)

  def resolve_principal(ref, default_type) when is_binary(ref) do
    cond do
      String.contains?(ref, "@") ->
        case Accounts.get_user_by_email(String.trim(ref)) do
          %User{id: id} -> {:ok, %{type: :user, id: id}}
          _ -> {:error, :unknown_principal}
        end

      is_binary(Repo.uuid_or_nil(ref)) ->
        {:ok, %{type: default_type, id: ref}}

      true ->
        {:error, :invalid_principal}
    end
  end

  def resolve_principal(_, _), do: {:error, :invalid_principal}

  @doc """
  The API tokens holding a seat in this workspace, newest first.

  This is the token INVENTORY an owner needs to answer "which credentials can
  reach my workspace, and are any of them stale?" — `Barkpark.Auth.list_tokens/1`
  answers a different question (every token bound to a DATASET string) and is
  not workspace-scoped, so it cannot serve this. Secrets are never selected;
  the row carries id, label, permissions, kind and lifecycle stamps only.
  """
  @spec list_workspace_tokens(binary()) :: [map()]
  def list_workspace_tokens(workspace_id, opts \\ [])

  def list_workspace_tokens(workspace_id, opts) when is_binary(workspace_id) and is_list(opts) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        []

      uuid ->
        Repo.all(
          paged(
            from(t in ApiToken,
              join: m in Membership,
              on: m.principal_id == t.id and m.principal_type == "api_token",
              where: m.workspace_id == ^uuid,
              # `desc: t.inserted_at` ALONE is a partial order — two tokens
              # minted in the same microsecond can swap places between the two
              # requests that read page 1 and page 2, which silently drops one
              # and repeats the other. `asc: t.id` makes it total.
              order_by: [desc: t.inserted_at, asc: t.id],
              select: %{
                id: t.id,
                label: t.label,
                name: t.name,
                kind: t.kind,
                permissions: t.permissions,
                dataset: t.dataset,
                role: m.role,
                revoked_at: t.revoked_at,
                expires_at: t.expires_at,
                last_used_at: t.last_used_at,
                inserted_at: t.inserted_at
              }
            ),
            opts
          )
        )
    end
  end

  def list_workspace_tokens(_, _), do: []

  @doc """
  How many tokens hold a seat here — the grand total behind a
  `list_workspace_tokens/2` page.
  """
  @spec count_workspace_tokens(binary()) :: non_neg_integer()
  def count_workspace_tokens(workspace_id) when is_binary(workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        0

      uuid ->
        Repo.aggregate(
          from(t in ApiToken,
            join: m in Membership,
            on: m.principal_id == t.id and m.principal_type == "api_token",
            where: m.workspace_id == ^uuid
          ),
          :count
        )
    end
  end

  def count_workspace_tokens(_), do: 0

  # A page window applied IN THE DATABASE. `:limit` absent means "every row" —
  # the in-process callers keep the old whole-list behaviour, while the HTTP
  # surface always passes one.
  defp paged(query, opts) do
    query =
      case Keyword.get(opts, :limit) do
        limit when is_integer(limit) and limit > 0 -> from(q in query, limit: ^limit)
        _ -> query
      end

    case Keyword.get(opts, :offset) do
      offset when is_integer(offset) and offset > 0 -> from(q in query, offset: ^offset)
      _ -> query
    end
  end

  @doc """
  True when the token holds a seat in this workspace.

  The cross-tenant rail for token revocation: an admin of workspace A must not
  be able to revoke a credential that belongs only to workspace B by guessing
  its id. Revocation endpoints call this FIRST and 404 on false — an id that
  names no seat here is indistinguishable from an id that does not exist,
  which is the correct answer to give a caller with no business knowing.
  """
  @spec token_member?(binary(), binary()) :: boolean()
  def token_member?(workspace_id, token_id)
      when is_binary(workspace_id) and is_binary(token_id) do
    match?(%Membership{}, TenancyAuth.membership(token_id, workspace_id, :api_token))
  end

  def token_member?(_, _), do: false

  # ── internals ──────────────────────────────────────────────────────────────

  defp delete_membership(%Membership{} = membership) do
    case Repo.delete(membership) do
      {:ok, deleted} -> {:ok, decorate_one(deleted)}
      {:error, _changeset} -> {:error, :delete_failed}
    end
  end

  # A demotion is only dangerous when it takes the LAST owner off the owner
  # role. Re-setting an owner to `owner` is a no-op and must not be refused.
  defp demotes_last_owner?(%Membership{role: @owner_role} = membership, new_role)
       when new_role != @owner_role,
       do: last_owner?(membership)

  defp demotes_last_owner?(_membership, _new_role), do: false

  defp last_owner?(%Membership{workspace_id: workspace_id, id: id}) do
    owners =
      Repo.aggregate(
        from(m in Membership,
          where: m.workspace_id == ^workspace_id and m.role == ^@owner_role and m.id != ^id
        ),
        :count
      )

    owners == 0
  end

  defp valid_role_names(workspace_id) do
    # Mirrors `Tenancy.Auth.create_membership/4`: built-ins plus this
    # workspace's custom roles, so an update accepts exactly what a create
    # would. Kept as a query here rather than exported from Auth to avoid
    # widening that module's public surface for one caller.
    custom =
      Repo.all(
        from(r in Barkpark.Tenancy.Role,
          where: r.workspace_id == ^workspace_id or is_nil(r.workspace_id),
          select: r.name
        )
      )

    Enum.uniq(Membership.roles() ++ custom)
  end

  defp identities(memberships, "user") do
    ids = for %{principal_type: "user", principal_id: id} <- memberships, do: id

    if ids == [] do
      %{}
    else
      Repo.all(from(u in User, where: u.id in ^ids, select: {u.id, u.email})) |> Map.new()
    end
  end

  defp identities(memberships, "api_token") do
    ids = for %{principal_type: "api_token", principal_id: id} <- memberships, do: id

    if ids == [] do
      %{}
    else
      from(t in ApiToken,
        where: t.id in ^ids,
        select: {t.id, %{label: t.label, permissions: t.permissions, revoked_at: t.revoked_at}}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  defp decorate_one(%Membership{principal_type: type} = membership) do
    decorate(
      membership,
      identities([membership], "user"),
      identities([membership], "api_token")
    )
    |> Map.put(:principal_type, type)
  end

  defp decorate(%Membership{principal_type: "user"} = m, users, _tokens) do
    %{
      principal_type: "user",
      principal_id: m.principal_id,
      role: m.role,
      identity: Map.get(users, m.principal_id),
      permissions: nil,
      revoked: nil,
      inserted_at: m.inserted_at
    }
  end

  defp decorate(%Membership{principal_type: "api_token"} = m, _users, tokens) do
    token = Map.get(tokens, m.principal_id)

    %{
      principal_type: "api_token",
      principal_id: m.principal_id,
      role: m.role,
      identity: token && token.label,
      permissions: token && token.permissions,
      revoked: token && not is_nil(token.revoked_at),
      inserted_at: m.inserted_at
    }
  end

  defp normalize_email(email) do
    case String.trim(email) do
      "" ->
        {:error, :invalid_email}

      trimmed ->
        if String.contains?(trimmed, "@"), do: {:ok, trimmed}, else: {:error, :invalid_email}
    end
  end
end
