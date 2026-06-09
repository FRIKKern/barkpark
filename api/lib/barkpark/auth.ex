defmodule Barkpark.Auth do
  @moduledoc "Context for API token authentication."

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Sharing
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # P5 share-edit token TTL policy (owner decision 2026-06-09): default 7 days,
  # hard cap 1 year. Write access is higher-risk than the anonymous read share,
  # so an edit token always expires.
  @share_token_default_ttl 7 * 24 * 3600
  @share_token_max_ttl 365 * 24 * 3600

  # The ONLY surfaces an edit token may cover. Papers-edit is out of scope (it
  # rides the Bulldocs shared-secret ingest API, a different auth model).
  @editable_surfaces ~w(docs media)

  def verify_token(raw_token) do
    hash = ApiToken.hash_token(raw_token)
    now = DateTime.utc_now()

    # Revocation + expiry are enforced in the WHERE clause, not post-filter:
    # a revoked or expired token must look identical to a missing one
    # (`{:error, :unauthorized}`), with no opportunity to leak its existence.
    ApiToken
    |> where([t], t.token_hash == ^hash)
    |> where([t], is_nil(t.revoked_at))
    |> where([t], is_nil(t.expires_at) or t.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :unauthorized}
      token -> {:ok, token}
    end
  end

  @doc """
  Revoke an API token — sets `revoked_at` to now so `verify_token/1` rejects
  it without a DB delete. Accepts an `ApiToken` struct or a token id. Idempotent
  on an already-revoked token (re-stamps `revoked_at`). The revocation primitive
  — no HTTP route is wired yet.
  """
  @spec revoke_token(ApiToken.t() | binary()) ::
          {:ok, ApiToken.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke_token(%ApiToken{} = token) do
    token
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  def revoke_token(token_id) when is_binary(token_id) do
    case Repo.get(ApiToken, token_id) do
      nil -> {:error, :not_found}
      token -> revoke_token(token)
    end
  end

  @doc """
  Mint an API token. When `workspace_id` is given (the tenancy-aware path),
  the token is bound to that workspace AND a `Barkpark.Tenancy.Membership`
  row is created in the same transaction — role derived from permissions
  ("admin" perm → "admin", else "member"). The token + membership commit
  atomically, so a failed membership insert rolls the token back.

  When `workspace_id` is `nil` the token falls back to the seeded Default
  Workspace if one exists (the backfill's target); when no Default Workspace
  exists the token is created un-bound (no membership) for back-compat with
  pre-tenancy callers and the existing test suite.
  """
  def create_token(raw_token, label, dataset, permissions, workspace_id \\ nil) do
    ws_id = workspace_id || default_workspace_id()

    token_attrs = %{
      token_hash: ApiToken.hash_token(raw_token),
      label: label,
      dataset: dataset,
      permissions: permissions,
      workspace_id: ws_id
    }

    if is_nil(ws_id) do
      %ApiToken{}
      |> ApiToken.changeset(token_attrs)
      |> Repo.insert()
    else
      insert_token_with_membership(token_attrs, ws_id, permissions)
    end
  end

  defp insert_token_with_membership(token_attrs, ws_id, permissions) do
    role = TenancyAuth.role_for_permissions(permissions)

    Repo.transaction(fn ->
      with {:ok, token} <- %ApiToken{} |> ApiToken.changeset(token_attrs) |> Repo.insert(),
           {:ok, _membership} <- TenancyAuth.create_membership(ws_id, token.id, role) do
        token
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp default_workspace_id do
    case Tenancy.get_default_workspace() do
      nil -> nil
      ws -> ws.id
    end
  end

  def list_tokens(dataset) do
    ApiToken
    |> where([t], t.dataset == ^dataset)
    |> Repo.all()
  end

  # ── P5: scoped-share EDIT tokens ───────────────────────────────────────

  @doc """
  Mint a SCOPED, REVOCABLE edit token for a `(workspace, project, dataset)`
  scope that is currently `:edit`-shared for the requested `surfaces`
  (subset of `#{inspect(@editable_surfaces)}`).

  The token is deliberately INERT everywhere except that exact shared scope:

    * its permissions are OPAQUE (`"share-edit-<surface>"`) — NOT `"write"` /
      `"admin"` — so it satisfies no global perm tier and cannot drive the flat
      mutate route or any membership-gated route;
    * it gets NO `Membership` row (a plain `Repo.insert`, not
      `insert_token_with_membership/3`), so every normal scoped route denies it;
    * `share_scope` byte-binds it to one `"ws/proj/dataset"`.

  Defense-in-depth: refuses to mint unless the scope is live-`:edit`-shared for
  every requested surface RIGHT NOW. `opts`: `:ttl` (seconds, default 7 days,
  capped at 1 year), `:label`. Returns `{:ok, {raw_token, %ApiToken{}}}` — the
  raw token is shown ONCE and never recoverable after.
  """
  @spec create_share_token(binary(), binary(), binary(), [binary() | atom()], keyword()) ::
          {:ok, {binary(), ApiToken.t()}} | {:error, term()}
  def create_share_token(ws_slug, proj_slug, dataset, surfaces, opts \\ [])

  def create_share_token(ws_slug, proj_slug, dataset, surfaces, opts)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) and
             is_list(surfaces) do
    surfaces = surfaces |> Enum.map(&to_string/1) |> Enum.uniq()

    with :ok <- validate_edit_share(ws_slug, proj_slug, dataset, surfaces),
         %Tenancy.Workspace{} = ws <-
           Tenancy.get_workspace_by_slug(ws_slug) || {:error, :unknown_scope},
         %Tenancy.Project{} <-
           Tenancy.get_project(ws_slug, proj_slug) || {:error, :unknown_scope} do
      raw = "bpshare_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        token_hash: ApiToken.hash_token(raw),
        label: opts[:label] || "share-edit #{ws_slug}/#{proj_slug}/#{dataset}",
        dataset: dataset,
        # permissions are NON-OVERRIDABLE — derived only from validated surfaces,
        # never caller-supplied (a caller could otherwise inject "admin").
        permissions: Enum.map(surfaces, &"share-edit-#{&1}"),
        workspace_id: ws.id,
        share_scope: "#{ws_slug}/#{proj_slug}/#{dataset}",
        expires_at: DateTime.add(now, clamp_ttl(opts[:ttl]))
      }

      case %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
        {:ok, token} -> {:ok, {raw, token}}
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def create_share_token(_ws, _proj, _ds, _surfaces, _opts), do: {:error, :invalid_args}

  @doc """
  Hard-revoke (stamp `revoked_at`) every share token bound to the exact
  `(ws, proj, dataset)` scope. Called from `Sharing.remove_share/3` so deleting
  a share also kills its edit tokens. Returns `{:ok, count_revoked}`.
  """
  @spec revoke_share_tokens(binary(), binary(), binary()) :: {:ok, non_neg_integer()}
  def revoke_share_tokens(ws_slug, proj_slug, dataset)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) do
    scope = "#{ws_slug}/#{proj_slug}/#{dataset}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      ApiToken
      |> where([t], t.share_scope == ^scope and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

    {:ok, count}
  end

  @doc """
  List share tokens (those carrying a `share_scope`), newest first, optionally
  filtered to one scope. Returns the rows — callers MUST NOT expose `token_hash`.
  """
  @spec list_share_tokens(binary() | nil) :: [ApiToken.t()]
  def list_share_tokens(scope \\ nil) do
    query =
      ApiToken
      |> where([t], not is_nil(t.share_scope))
      |> order_by([t], desc: t.inserted_at)

    query = if scope, do: where(query, [t], t.share_scope == ^scope), else: query
    Repo.all(query)
  end

  defp validate_edit_share(ws, proj, dataset, surfaces) do
    cond do
      surfaces == [] ->
        {:error, :no_surfaces}

      Enum.any?(surfaces, &(&1 not in @editable_surfaces)) ->
        {:error, :unsupported_surface}

      Sharing.access_for(ws, proj, dataset) != :edit ->
        {:error, :not_edit_shared}

      not Enum.all?(surfaces, &Sharing.shared?(ws, proj, dataset, &1)) ->
        {:error, :surface_not_shared}

      true ->
        :ok
    end
  end

  defp clamp_ttl(nil), do: @share_token_default_ttl
  defp clamp_ttl(ttl) when is_integer(ttl) and ttl > 0, do: min(ttl, @share_token_max_ttl)
  defp clamp_ttl(_), do: @share_token_default_ttl

  # `token.permissions || []` keeps this total: a nil permissions array (e.g. a
  # NULL DB column) denies (false) instead of raising `ArgumentError` on
  # `permission in nil`. nil permissions → deny, never raise.
  def has_permission?(token, permission) do
    permission in (token.permissions || [])
  end
end
