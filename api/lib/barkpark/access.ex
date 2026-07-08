defmodule Barkpark.Access do
  @moduledoc """
  The **access-grants** context — mint / lookup / claim / revoke / validate for
  airdrop grants (`Barkpark.Access.Grant`).

  A grant is a shareable, time-boxed, account-bound scoped capability. An
  existing principal MINTS one for a grantee (by email); the raw link token is
  returned exactly once and handed over out-of-band. The grantee CLAIMS it
  (binding it to their account), and thereafter the grant VALIDATES scoped
  actions at read time.

  ## Fail-closed invariants

    * **No escalation at mint.** A grantor can only confer capabilities it
      itself holds in the workspace — each requested capability is checked
      through `Barkpark.Tenancy.Auth.authorize/3` before the grant is written.
    * **Active is derived, in-query.** `lookup_by_token/1` and the `list_*`
      readers filter the active predicate (not revoked, not expired, and — for
      single-use — not yet claimed) in SQL; there is no `active` column.
    * **Claim is atomic.** `claim/2` conditionally updates `WHERE claimed_at IS
      NULL`, so two concurrent claims cannot both succeed.
    * **UUID-guarded reads.** `get_grant/1` and `revoke/2` cast the id first, so
      a non-UUID string is a clean `nil`/`:not_found`, never a 500.
    * **Scope containment is total.** `validate/3` denies any requested scope
      that escapes the grant's scope ladder.
  """
  import Ecto.Query, warn: false

  alias Barkpark.Repo
  alias Barkpark.Access.Grant
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth

  # Scope ladder, broad → narrow. A NULL on the grant at any level means
  # "everything below that level is covered".
  @ladder [:workspace_id, :project_id, :dataset, :type, :doc_id]

  @type principal :: User.t() | ApiToken.t()
  @type action :: :read | :write | :admin

  # ---------------------------------------------------------------------------
  # mint
  # ---------------------------------------------------------------------------

  @doc """
  Mint a grant on behalf of `principal`. Returns `{:ok, %{grant: grant, token:
  raw_token}}` — the raw token is returned ONCE and never stored (only its
  SHA-256 hash is persisted).

  No-escalation gate: every requested capability is authorized against
  `principal` in the grant's workspace via `Barkpark.Tenancy.Auth.authorize/3`.
  If the grantor lacks any requested capability (or the principal is
  unrecognised, or the workspace is missing), returns `{:error, :forbidden}`.
  Changeset failures (e.g. an unknown capability, missing required scope)
  return `{:error, %Ecto.Changeset{}}`.
  """
  @spec mint(principal(), map()) ::
          {:ok, %{grant: Grant.t(), token: String.t()}}
          | {:error, :forbidden | Ecto.Changeset.t()}
  def mint(principal, attrs) when is_map(attrs) do
    with {:ok, grantor_id} <- principal_id(principal),
         workspace_id when is_binary(workspace_id) <- fetch(attrs, :workspace_id),
         caps = fetch(attrs, :capabilities) || [],
         :ok <- authorize_capabilities(principal, workspace_id, caps) do
      raw = generate_token()

      insert_attrs =
        attrs
        |> stringify_keys()
        |> Map.put("grantor_id", grantor_id)
        |> Map.put("link_token_hash", hash_token(raw))

      case %Grant{} |> Grant.changeset(insert_attrs) |> Repo.insert() do
        {:ok, grant} -> {:ok, %{grant: grant, token: raw}}
        {:error, changeset} -> {:error, changeset}
      end
    else
      _ -> {:error, :forbidden}
    end
  end

  # ---------------------------------------------------------------------------
  # lookup / get / list
  # ---------------------------------------------------------------------------

  @doc """
  Resolve an ACTIVE grant by its raw token, or `nil`. Missing, expired, revoked,
  and spent single-use grants all resolve to `nil` (the active predicate is
  applied in-query).
  """
  @spec lookup_by_token(String.t()) :: Grant.t() | nil
  def lookup_by_token(raw_token) when is_binary(raw_token) do
    hash = hash_token(raw_token)

    Grant
    |> active_where(DateTime.utc_now())
    |> where([g], g.link_token_hash == ^hash)
    |> Repo.one()
  end

  def lookup_by_token(_), do: nil

  @doc """
  Fetch a grant by id, UUID-guarded. A non-UUID string returns `nil` (never a
  cast crash).
  """
  @spec get_grant(String.t()) :: Grant.t() | nil
  def get_grant(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Grant, uuid)
      :error -> nil
    end
  end

  def get_grant(_), do: nil

  @doc "List ACTIVE grants bound to a grantee user (active filtered in-query)."
  @spec list_active_grants_for_grantee(String.t()) :: [Grant.t()]
  def list_active_grants_for_grantee(user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, uuid} ->
        Grant
        |> active_where(DateTime.utc_now())
        |> where([g], g.grantee_user_id == ^uuid)
        |> Repo.all()

      :error ->
        []
    end
  end

  def list_active_grants_for_grantee(_), do: []

  @doc "List ACTIVE grants scoped to a workspace (active filtered in-query)."
  @spec list_grants_for_workspace(String.t()) :: [Grant.t()]
  def list_grants_for_workspace(workspace_id) when is_binary(workspace_id) do
    case Ecto.UUID.cast(workspace_id) do
      {:ok, uuid} ->
        Grant
        |> active_where(DateTime.utc_now())
        |> where([g], g.workspace_id == ^uuid)
        |> Repo.all()

      :error ->
        []
    end
  end

  def list_grants_for_workspace(_), do: []

  # ---------------------------------------------------------------------------
  # claim
  # ---------------------------------------------------------------------------

  @doc """
  Claim a grant for `user`, binding `grantee_user_id` + `claimed_at`. Atomic:
  the update is conditional on `claimed_at IS NULL`, so a double-claim (or a
  race) yields `{:error, :already_claimed}`.

    * missing / revoked token → `{:error, :not_found}`
    * expired grant → `{:error, :expired}`
    * already-claimed grant → `{:error, :already_claimed}`
  """
  @spec claim(String.t(), User.t()) ::
          {:ok, Grant.t()} | {:error, :not_found | :already_claimed | :expired}
  def claim(raw_token, %User{id: user_id}) when is_binary(raw_token) do
    hash = hash_token(raw_token)

    case Repo.one(from g in Grant, where: g.link_token_hash == ^hash) do
      nil ->
        {:error, :not_found}

      %Grant{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :not_found}

      %Grant{} = grant ->
        if expired?(grant), do: {:error, :expired}, else: do_claim(grant, user_id)
    end
  end

  def claim(_raw_token, _user), do: {:error, :not_found}

  defp do_claim(%Grant{id: id}, user_id) do
    now = DateTime.utc_now()

    query = from g in Grant, where: g.id == ^id and is_nil(g.claimed_at)

    case Repo.update_all(query, set: [grantee_user_id: user_id, claimed_at: now]) do
      {1, _} -> {:ok, Repo.get(Grant, id)}
      {0, _} -> {:error, :already_claimed}
    end
  end

  # ---------------------------------------------------------------------------
  # revoke
  # ---------------------------------------------------------------------------

  @doc """
  Revoke a grant, stamping `revoked_at`. Idempotent — revoking an
  already-revoked grant is a `{:ok, grant}` no-op. UUID-guarded; a non-UUID id
  (or a missing grant) is `{:error, :not_found}`.

  Only the original grantor or a workspace admin may revoke; anyone else gets
  `{:error, :forbidden}`.
  """
  @spec revoke(String.t(), principal()) ::
          {:ok, Grant.t()} | {:error, :forbidden | :not_found}
  def revoke(id, principal) when is_binary(id) do
    case get_grant(id) do
      nil ->
        {:error, :not_found}

      %Grant{revoked_at: revoked} = grant when not is_nil(revoked) ->
        with :ok <- authorize_revoke(principal, grant), do: {:ok, grant}

      %Grant{} = grant ->
        with :ok <- authorize_revoke(principal, grant) do
          grant
          |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
          |> Repo.update()
        end
    end
  end

  def revoke(_id, _principal), do: {:error, :not_found}

  defp authorize_revoke(principal, %Grant{} = grant) do
    cond do
      principal_matches?(principal, grant.grantor_id) -> :ok
      Auth.authorize(principal, grant.workspace_id, :admin) == :ok -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp principal_matches?(%User{id: id}, grantor_id), do: id == grantor_id
  defp principal_matches?(%ApiToken{id: id}, grantor_id), do: id == grantor_id
  defp principal_matches?(_, _), do: false

  # ---------------------------------------------------------------------------
  # validate
  # ---------------------------------------------------------------------------

  @doc """
  Validate that `action` at `scope` is permitted by a grant (a `%Grant{}` or a
  raw token). Total and fail-closed:

    * revoked → `{:error, :revoked}`
    * expired (or spent single-use) → `{:error, :expired}` / `{:error, :forbidden}`
    * action not in the grant's capabilities → `{:error, :forbidden}`
    * requested scope escapes the grant's scope ladder → `{:error, :forbidden}`
    * otherwise → `:ok`

  `scope` is a map keyed by any of `:workspace_id`, `:project_id`, `:dataset`,
  `:type`, `:doc_id` (string keys accepted too).
  """
  @spec validate(Grant.t() | String.t(), action() | String.t(), map()) ::
          :ok | {:error, :forbidden | :expired | :revoked}
  def validate(%Grant{} = grant, action, scope) when is_map(scope) do
    do_validate(grant, action, scope)
  end

  def validate(raw_token, action, scope) when is_binary(raw_token) and is_map(scope) do
    hash = hash_token(raw_token)

    case Repo.one(from g in Grant, where: g.link_token_hash == ^hash) do
      nil -> {:error, :forbidden}
      %Grant{} = grant -> do_validate(grant, action, scope)
    end
  end

  def validate(_grant, _action, _scope), do: {:error, :forbidden}

  defp do_validate(%Grant{} = grant, action, scope) do
    cond do
      not is_nil(grant.revoked_at) -> {:error, :revoked}
      expired?(grant) -> {:error, :expired}
      grant.single_use and not is_nil(grant.claimed_at) -> {:error, :forbidden}
      not action_allowed?(grant, action) -> {:error, :forbidden}
      not scope_contained?(grant, scope) -> {:error, :forbidden}
      true -> :ok
    end
  end

  defp action_allowed?(%Grant{capabilities: caps}, action) when is_atom(action) and is_list(caps),
    do: Atom.to_string(action) in caps

  defp action_allowed?(%Grant{capabilities: caps}, action)
       when is_binary(action) and is_list(caps),
       do: action in caps

  defp action_allowed?(_grant, _action), do: false

  # The one genuinely-new algorithm: scope CONTAINMENT down the ladder. Walk
  # workspace → project → dataset → type → doc_id. A NULL on the grant at a
  # level means "everything below is covered" → contained (stop, allow). A
  # non-NULL grant level must EXACTLY match the requested value; a mismatch — or
  # a request that omits/broadens that level — is an escape → deny. Total and
  # fail-closed: anything not proven at-or-under the grant is refused.
  defp scope_contained?(%Grant{} = grant, scope) when is_map(scope) do
    Enum.reduce_while(@ladder, true, fn level, _acc ->
      grant_val = Map.get(grant, level)
      req_val = fetch(scope, level)

      cond do
        is_nil(grant_val) -> {:halt, true}
        req_val == grant_val -> {:cont, true}
        true -> {:halt, false}
      end
    end)
  end

  defp scope_contained?(_grant, _scope), do: false

  # ---------------------------------------------------------------------------
  # internals
  # ---------------------------------------------------------------------------

  # Add the DERIVED active predicate to a query. Kept in one place so every
  # reader (lookup + lists) shares one source of truth.
  defp active_where(query, %DateTime{} = now) do
    from g in query,
      where:
        is_nil(g.revoked_at) and
          (is_nil(g.expires_at) or g.expires_at > ^now) and
          (g.single_use == false or is_nil(g.claimed_at))
  end

  defp expired?(%Grant{expires_at: nil}), do: false

  defp expired?(%Grant{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  # No-escalation gate: a grantor can only confer capabilities it itself holds.
  # Each capability maps to an authz action; an unknown capability (or any
  # authorize denial) fails the whole mint, closed.
  defp authorize_capabilities(principal, workspace_id, caps)
       when is_binary(workspace_id) and is_list(caps) and caps != [] do
    Enum.reduce_while(caps, :ok, fn cap, :ok ->
      with {:ok, action} <- cap_to_action(cap),
           :ok <- Auth.authorize(principal, workspace_id, action) do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :forbidden}}
      end
    end)
  end

  defp authorize_capabilities(_principal, _workspace_id, _caps), do: {:error, :forbidden}

  defp cap_to_action("read"), do: {:ok, :read}
  defp cap_to_action("write"), do: {:ok, :write}
  defp cap_to_action("admin"), do: {:ok, :admin}
  defp cap_to_action(_), do: :error

  defp principal_id(%User{id: id}) when is_binary(id), do: {:ok, id}
  defp principal_id(%ApiToken{id: id}) when is_binary(id), do: {:ok, id}
  defp principal_id(_), do: {:error, :forbidden}

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  # Read a value from an attrs/scope map tolerant of atom OR string keys.
  defp fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
