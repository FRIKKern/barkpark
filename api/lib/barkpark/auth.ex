defmodule Barkpark.Auth do
  @moduledoc "Context for API token authentication."

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Auth.LoginTicket
  alias Barkpark.Sharing
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # dwb-7 login-ticket TTL: 60s. A one-time handoff URL is used immediately
  # (control plane mints it, browser opens it), so the window is deliberately
  # tiny — single-use + short TTL are the two mitigations for consuming on GET.
  @login_ticket_ttl_seconds 60

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

  # ── dwb-7: single-use login handoff tickets ─────────────────────────────

  @doc """
  Mint a single-use, 60s login ticket bound to `raw_api_token` (dwb-7).

  The caller must prove possession of a LIVE api_token — this re-verifies it
  (`verify_token/1`), so a revoked/expired token cannot mint. The opaque ticket
  is stored only as its SHA-256 hash; the raw api_token is held encrypted at
  rest (`Barkpark.EncryptedBinary`) so `consume_login_ticket/1` can later drop
  the RAW token into the session (what LiveAuth verifies). Returns
  `{:ok, raw_ticket}` — the raw ticket is returned ONCE and never recoverable —
  or `{:error, :unauthorized}` for a bad/expired/revoked token.

  Never log the returned ticket or the api_token; never place the api_token in a
  URL. Only the ticket travels in the handoff URL.
  """
  @spec mint_login_ticket(binary()) :: {:ok, binary()} | {:error, :unauthorized}
  def mint_login_ticket(raw_api_token) when is_binary(raw_api_token) do
    case verify_token(raw_api_token) do
      {:ok, _token} ->
        raw_ticket = "bplt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        now = DateTime.utc_now()

        attrs = %{
          ticket_hash: hash_ticket(raw_ticket),
          api_token: raw_api_token,
          expires_at: DateTime.add(now, @login_ticket_ttl_seconds)
        }

        case %LoginTicket{} |> LoginTicket.changeset(attrs) |> Repo.insert() do
          {:ok, _ticket} -> {:ok, raw_ticket}
          {:error, _changeset} -> {:error, :unauthorized}
        end

      {:error, :unauthorized} ->
        {:error, :unauthorized}
    end
  end

  def mint_login_ticket(_), do: {:error, :unauthorized}

  @doc """
  Atomically consume a login ticket, returning the bound RAW api_token (dwb-7).

  Single-use is enforced by a race-safe `UPDATE ... WHERE used_at IS NULL AND
  not-expired` that stamps `used_at` and returns the row: under Postgres READ
  COMMITTED two concurrent consumes serialize on the row lock and the second
  re-evaluates the WHERE against the now-spent row, so EXACTLY ONE wins (count
  == 1). An unknown, already-used, or expired ticket all return the SAME
  `{:error, :invalid}` — no oracle distinguishes the failure kinds.
  """
  @spec consume_login_ticket(binary()) :: {:ok, binary()} | {:error, :invalid}
  def consume_login_ticket(raw_ticket) when is_binary(raw_ticket) do
    hash = hash_ticket(raw_ticket)
    now = DateTime.utc_now()

    # `select:` (NOT the `:returning` opt — update_all silently ignores it and
    # yields `{count, nil}`) both returns the winner's payload and routes it
    # through the schema type, so the EncryptedBinary ciphertext comes back
    # DECRYPTED as the raw api_token.
    query =
      from t in LoginTicket,
        where: t.ticket_hash == ^hash and is_nil(t.used_at) and t.expires_at > ^now,
        select: t.api_token

    case Repo.update_all(query, set: [used_at: now]) do
      {1, [raw_api_token]} -> {:ok, raw_api_token}
      _ -> {:error, :invalid}
    end
  end

  def consume_login_ticket(_), do: {:error, :invalid}

  @doc """
  Delete expired or spent login tickets. Best-effort GC — returns the count
  removed. A spent/expired row carries no live secret (its api_token is only
  reachable by a WINNING consume, which never happens again), so retention is a
  hygiene concern, not a security one.
  """
  @spec sweep_login_tickets() :: non_neg_integer()
  def sweep_login_tickets do
    now = DateTime.utc_now()

    {count, _} =
      LoginTicket
      |> where([t], not is_nil(t.used_at) or t.expires_at <= ^now)
      |> Repo.delete_all()

    count
  end

  @doc false
  @spec hash_ticket(binary()) :: binary()
  def hash_ticket(raw_ticket) do
    :crypto.hash(:sha256, raw_ticket) |> Base.encode16(case: :lower)
  end

  @doc "The login-ticket TTL in seconds (the mint response's `expires_in`)."
  @spec login_ticket_ttl_seconds() :: pos_integer()
  def login_ticket_ttl_seconds, do: @login_ticket_ttl_seconds

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
    # Guard the UUID cast: the id column is :binary_id, so a non-UUID token_id
    # (e.g. from `DELETE /v1/shares/tokens/garbage`) would raise Ecto.CastError
    # → 500. A malformed id can't identify any row, so it's a clean not_found.
    case Repo.uuid_or_nil(token_id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(ApiToken, uuid) do
          nil -> {:error, :not_found}
          token -> revoke_token(token)
        end
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

  # ── PAT fast-follow: self-service Personal Access Tokens ───────────────

  # PAT TTL policy: default 30 days, hard-capped at 1 year. A PAT is a
  # longer-lived self-service credential than the dev token, so it always
  # carries a finite horizon (mirrors cloud/'s bounded expiry).
  @pat_default_ttl 30 * 24 * 3600
  @pat_max_ttl 365 * 24 * 3600
  @pat_token_prefix "bppat_"

  # Roles that may mint write/admin tokens. A `member` may only mint a read
  # token (Coolify's ApiTokenPolicy: only admin/owner mint elevated tokens —
  # app/Policies/ApiTokenPolicy.php).
  @pat_admin_roles ~w(owner admin)
  @pat_allowed_member_permissions ~w(read)
  @pat_allowed_admin_permissions ~w(read write admin)

  @doc """
  Mint a self-service Personal Access Token, ROLE-GATED on the minting admin's
  workspace role. The `:role` opt is the minter's workspace role (the Studio
  pane passes the current admin's role); a `member` may mint only `["read"]`,
  an `owner`/`admin` may mint up to `["read", "write", "admin"]`. A request to
  mint above the role returns `{:error, :forbidden}` (the server is the
  authority — never trust a client-supplied permission set).

  Unlike `create_token/5`, this sets `name` (user-facing) + `created_by` (audit)
  + a bounded `expires_at`, and prefixes the raw token with `#{@pat_token_prefix}`
  for leak-scanner recognisability. Returns `{:ok, {raw_token, %ApiToken{}}}` —
  the raw token is shown ONCE and never recoverable after.

  `opts`: `:role` (default `"member"`), `:workspace_id`, `:dataset`
  (default `"production"`), `:created_by`, `:ttl` (seconds; `nil` = never;
  default 30 days; capped at 1 year).
  """
  @spec create_personal_access_token(binary(), [binary()], keyword()) ::
          {:ok, {binary(), ApiToken.t()}} | {:error, :forbidden | Ecto.Changeset.t()}
  def create_personal_access_token(name, permissions, opts \\ [])
      when is_binary(name) and is_list(permissions) do
    role = Keyword.get(opts, :role, "member")

    with :ok <- authorize_pat_permissions(role, permissions) do
      raw = @pat_token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      ws_id = Keyword.get(opts, :workspace_id) || default_workspace_id()

      expires_at =
        case Keyword.get(opts, :ttl, @pat_default_ttl) do
          nil ->
            nil

          ttl ->
            DateTime.utc_now()
            |> DateTime.add(clamp_pat_ttl(ttl))
            |> DateTime.truncate(:second)
        end

      token_attrs = %{
        token_hash: ApiToken.hash_token(raw),
        name: name,
        label: name,
        dataset: Keyword.get(opts, :dataset, "production"),
        permissions: permissions,
        workspace_id: ws_id,
        created_by: Keyword.get(opts, :created_by),
        expires_at: expires_at
      }

      result =
        if is_nil(ws_id) do
          %ApiToken{} |> ApiToken.changeset(token_attrs) |> Repo.insert()
        else
          insert_token_with_membership(token_attrs, ws_id, permissions)
        end

      case result do
        {:ok, token} -> {:ok, {raw, token}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  # Best-effort, throttled `last_used_at` stamp for a verified token. Called from
  # RequireToken so operators can spot dead tokens. Once/minute resolution — a
  # chatty token does not trigger a write per request. Errors are swallowed:
  # stamping liveness must never break auth.
  @pat_last_used_throttle_seconds 60

  @doc false
  @spec touch_last_used(ApiToken.t()) :: :ok
  def touch_last_used(%ApiToken{id: id, last_used_at: prev}) do
    now = DateTime.utc_now()

    stale? =
      is_nil(prev) or DateTime.diff(now, prev, :second) > @pat_last_used_throttle_seconds

    if stale? do
      stamp = DateTime.truncate(now, :microsecond)

      try do
        ApiToken
        |> where([t], t.id == ^id)
        |> Repo.update_all(set: [last_used_at: stamp])
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  def touch_last_used(_), do: :ok

  # Gate the requested permission set against the minter's workspace role.
  defp authorize_pat_permissions(role, permissions) do
    allowed =
      if role in @pat_admin_roles,
        do: @pat_allowed_admin_permissions,
        else: @pat_allowed_member_permissions

    if Enum.all?(permissions, &(&1 in allowed)) and permissions != [] do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp clamp_pat_ttl(ttl) when is_integer(ttl) and ttl > 0, do: min(ttl, @pat_max_ttl)
  defp clamp_pat_ttl(_), do: @pat_default_ttl

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
