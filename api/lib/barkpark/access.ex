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
  require Logger

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
  `principal` in the grant's workspace via
  `Barkpark.Tenancy.Auth.authorize_with_reason/3`.

  That gate is a TWO-ARM predicate — membership AND capability — and the two
  arms are reported apart, because collapsing them made the refusal name the
  wrong remedy (a grantor holding `admin` cannot fail the capability arm, so
  what failed was membership):

    * `{:error, :not_a_member}` — the grantor has no membership in the grant's
      workspace, whatever capabilities it holds elsewhere.
    * `{:error, :forbidden}` — the grantor IS a member but lacks a requested
      capability, or the capability is unknown, or the principal is
      unrecognised, or the workspace is missing. `:forbidden` keeps its old
      meaning so existing callers read unchanged.

  Changeset failures (e.g. an unknown capability, missing required scope)
  return `{:error, %Ecto.Changeset{}}`.
  """
  @spec mint(principal(), map()) ::
          {:ok, %{grant: Grant.t(), token: String.t()}}
          | {:error, :forbidden | :not_a_member | Ecto.Changeset.t()}
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
        {:ok, grant} ->
          emit_grant_event("grant.minted", grant, principal, %{
            "grantee_email" => grant.grantee_email,
            "capabilities" => grant.capabilities,
            "project_id" => grant.project_id,
            "dataset" => grant.dataset,
            "type" => grant.type,
            "doc_id" => grant.doc_id,
            "expires_at" => iso(grant.expires_at),
            "single_use" => grant.single_use
          })

          {:ok, %{grant: grant, token: raw}}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :not_a_member} -> {:error, :not_a_member}
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
    case Repo.uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Grant, uuid)
    end
  end

  def get_grant(_), do: nil

  @doc "List ACTIVE grants bound to a grantee user (active filtered in-query)."
  @spec list_active_grants_for_grantee(String.t()) :: [Grant.t()]
  def list_active_grants_for_grantee(user_id) when is_binary(user_id) do
    case Repo.uuid_or_nil(user_id) do
      nil ->
        []

      uuid ->
        Grant
        |> active_where(DateTime.utc_now())
        |> where([g], g.grantee_user_id == ^uuid)
        |> Repo.all()
    end
  end

  def list_active_grants_for_grantee(_), do: []

  @doc "List ACTIVE grants scoped to a workspace (active filtered in-query)."
  @spec list_grants_for_workspace(String.t()) :: [Grant.t()]
  def list_grants_for_workspace(workspace_id) when is_binary(workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil ->
        []

      uuid ->
        Grant
        |> active_where(DateTime.utc_now())
        |> where([g], g.workspace_id == ^uuid)
        |> Repo.all()
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
  def claim(raw_token, %User{} = user) when is_binary(raw_token) do
    hash = hash_token(raw_token)

    case Repo.one(from g in Grant, where: g.link_token_hash == ^hash) do
      nil ->
        {:error, :not_found}

      %Grant{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :not_found}

      %Grant{} = grant ->
        if expired?(grant), do: {:error, :expired}, else: do_claim(grant, user)
    end
  end

  def claim(_raw_token, _user), do: {:error, :not_found}

  defp do_claim(%Grant{id: id}, %User{id: user_id} = user) do
    now = DateTime.utc_now()

    query = from g in Grant, where: g.id == ^id and is_nil(g.claimed_at)

    case Repo.update_all(query, set: [grantee_user_id: user_id, claimed_at: now]) do
      {1, _} ->
        grant = Repo.get(Grant, id)

        emit_grant_event("grant.claimed", grant, user, %{
          "grantee_user_id" => user_id,
          "claimed_at" => iso(now)
        })

        {:ok, grant}

      {0, _} ->
        {:error, :already_claimed}
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
        with :ok <- authorize_revoke(principal, grant),
             {:ok, revoked_grant} <-
               grant
               |> Ecto.Changeset.change(revoked_at: DateTime.utc_now())
               |> Repo.update() do
          emit_grant_event("grant.revoked", revoked_grant, principal, %{
            "revoked_at" => iso(revoked_grant.revoked_at)
          })

          broadcast_revoked(revoked_grant)

          {:ok, revoked_grant}
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

  @doc """
  Admission for a **desk mount** — the Studio surface's granularity is
  `(workspace, project, dataset)`; a desk cannot name a `type` or `doc_id`.
  So a grant scoped BELOW the desk (a type/doc grant) must still be allowed to
  MOUNT its own project/dataset desk — the sub-desk narrowing then happens at
  read time via `Barkpark.Content.Scope.scope_to_grants/3`. Plain `validate/3`
  would DENY it (the grant's non-null `type`/`doc_id` escapes a desk request
  that omits them), which is why bare-workspace admission left every sub-scoped
  grantee locked out.

  `admits_desk?/3` validates the desk's `(workspace, project, dataset)` against
  the grant while treating the grant's OWN `type`/`doc_id` as satisfied (feeding
  them into the request), so ONLY the desk-granularity levels constrain
  admission. It REUSES `validate/3` — no parallel containment ladder.

  Fail-closed and NO-WIDEN: the merge only auto-satisfies the levels a desk
  cannot express (type/doc); the desk-granularity levels are still checked by
  `scope_contained?`, so a desk BROADER than the grant at ws/project/dataset (a
  `nil` where the grant is non-null — e.g. a project grant at a project-less or
  sibling-project desk) still escapes → `false`.
  """
  @spec admits_desk?(Grant.t(), action() | String.t(), map()) :: boolean()
  def admits_desk?(%Grant{} = grant, action, desk_scope) when is_map(desk_scope) do
    scope =
      desk_scope
      |> Map.put(:type, grant.type)
      |> Map.put(:doc_id, grant.doc_id)

    do_validate(grant, action, scope) == :ok
  end

  def admits_desk?(_grant, _action, _desk_scope), do: false

  defp do_validate(%Grant{} = grant, action, scope) do
    cond do
      not is_nil(grant.revoked_at) -> {:error, :revoked}
      expired?(grant) -> {:error, :expired}
      grant.single_use and not is_nil(grant.claimed_at) -> {:error, :forbidden}
      not action_allowed?(grant, action) -> {:error, :forbidden}
      not scope_contained?(grant, scope) -> {:error, :forbidden}
      not grantor_authorizes?(grant, action) -> {:error, :forbidden}
      true -> :ok
    end
  end

  @doc """
  LIVE grantor re-validation — the privilege-persistence gate (finding ag-1).

  A grant may only confer a capability while its GRANTOR still holds that
  capability in the grant's workspace, RIGHT NOW. Enforcement re-resolves the
  grantor principal from `grantor_id` and re-runs the SAME per-action
  `Barkpark.Tenancy.Auth.authorize/3` check the mint-time no-escalation gate
  (`authorize_capabilities/3`) used — so mint and enforcement AGREE: a grantor
  that mint would still allow is admitted; a grantor whose authority was
  removed (membership deleted), narrowed (role downgraded write→read), or
  invalidated (token revoked) no longer confers, EXCLUDING every grant it
  issued from that point on.

  Per-action: a grantor that kept `read` but lost `write` still confers read
  but not write. Fail-CLOSED: a grantor that can't be resolved to a live
  principal, or that no longer authorizes the action, → `false`.

  This is the ONE grantor predicate; it is the sole re-validation source shared
  by BOTH enforcement families — the per-action admission path (`validate/3` /
  `admits_desk?/3` via `do_validate`) AND the read-union row-narrowing path
  (`Barkpark.Content.Scope.scope_to_grants/3`) — so no path can admit a grant
  the other would deny.
  """
  @spec grantor_authorizes?(Grant.t(), action() | String.t()) :: boolean()
  def grantor_authorizes?(%Grant{} = grant, action) do
    with {:ok, act} <- normalize_action(action),
         principal when not is_nil(principal) <- resolve_grantor(grant.grantor_id) do
      Auth.authorize(principal, grant.workspace_id, act) == :ok
    else
      _ -> false
    end
  end

  def grantor_authorizes?(_grant, _action), do: false

  # Resolve the stored `grantor_id` back to the LIVE principal mint authorized
  # against. There is no `grantor_type` discriminator on the grant — `mint/2`
  # records only the id (via `principal_id/1`), for a User OR an ApiToken — so
  # we resolve by loading the row: a User first, else an ApiToken. User and
  # ApiToken carry independent random UUIDv4 primary keys in separate tables, so
  # an id matches at most one; this reconstructs EXACTLY the struct mint passed
  # to `Auth.authorize/3` (a User → membership role; an ApiToken → membership
  # AND its `permissions[]`), keeping mint and enforcement byte-identical.
  #
  # Fail-CLOSED: a non-UUID id, a deleted user/token, or a REVOKED token → nil
  # (grant excluded). A revoked token can no longer authenticate to mint at all
  # (`verify_token/1` rejects `revoked_at`), so excluding it here mirrors "mint
  # would no longer allow this grantor" — it is consistent with the mint gate,
  # not a divergence from it.
  defp resolve_grantor(grantor_id) when is_binary(grantor_id) do
    case Repo.uuid_or_nil(grantor_id) do
      nil -> nil
      uuid -> Repo.get(User, uuid) || live_token(uuid)
    end
  end

  defp resolve_grantor(_), do: nil

  defp live_token(uuid) do
    case Repo.get(ApiToken, uuid) do
      %ApiToken{revoked_at: nil} = token -> token
      _ -> nil
    end
  end

  # Coerce a validate/3 action (atom OR string) to the atom `Auth.authorize/3`
  # expects; anything else → :error → fail-closed deny.
  defp normalize_action(action) when action in [:read, :write, :admin], do: {:ok, action}
  defp normalize_action(action) when is_binary(action), do: cap_to_action(action)
  defp normalize_action(_), do: :error

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
  #
  # The denial CARRIES which arm refused. `authorize_with_reason/3` is the same
  # decision `authorize/3` makes (the latter is a collapse of the former), so
  # no second membership predicate is introduced here — only the reason the one
  # chokepoint already computed is preserved instead of discarded.
  defp authorize_capabilities(principal, workspace_id, caps)
       when is_binary(workspace_id) and is_list(caps) and caps != [] do
    Enum.reduce_while(caps, :ok, fn cap, :ok ->
      case cap_to_action(cap) do
        {:ok, action} ->
          case Auth.authorize_with_reason(principal, workspace_id, action) do
            :ok -> {:cont, :ok}
            {:error, :not_a_member} -> {:halt, {:error, :not_a_member}}
            {:error, _} -> {:halt, {:error, :forbidden}}
          end

        :error ->
          {:halt, {:error, :forbidden}}
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

  # ---------------------------------------------------------------------------
  # audit
  # ---------------------------------------------------------------------------

  # Record a grant lifecycle transition on the tenant-wide, tamper-evident audit
  # bus (finding #11). Grants are a privileged mint/claim/revoke surface, so —
  # like SSO/SCIM/WebAuthn/MFA/token producers — each transition lands on the
  # append-only hash chain. Side-record only: the emit return is IGNORED, so a
  # failed audit write can never break the grant operation (matching every other
  # `Audit.emit/1` producer, which discard the result). `workspace_id` is passed
  # top-level so the event chains into the grant's own per-workspace chain.
  #
  # FULLY ISOLATED: emit is also wrapped in rescue/catch (mirroring
  # `Barkpark.Audit.safe_bridge/1`), so an emit that RAISES at the infra layer
  # (advisory-lock `Repo.query!`, a DB connection blip) is swallowed-and-logged,
  # never propagated. The grant op still returns its normal `{:ok, grant}` even
  # though the grant already persisted — the additive guarantee holds on BOTH
  # the error-return AND the raise path.
  #
  # FIELD HYGIENE: metadata carries ONLY non-secret grant descriptors — NEVER
  # the raw token or `link_token_hash`. The audit records the grant, not the
  # secret.
  defp emit_grant_event(action, %Grant{} = grant, actor_principal, metadata) do
    {actor_type, actor_id} = actor_fields(actor_principal)

    Barkpark.Audit.emit(%{
      category: "access",
      action: action,
      subject: grant.id,
      actor_type: actor_type,
      actor_id: actor_id,
      workspace_id: grant.workspace_id,
      metadata: Map.put(metadata, "workspace_id", grant.workspace_id)
    })

    :ok
  rescue
    error ->
      Logger.error("grant audit emit failed for #{action}: #{Exception.message(error)}")
      :ok
  catch
    _, _ -> :ok
  end

  defp actor_fields(%User{id: id}), do: {"user", id}
  defp actor_fields(%ApiToken{id: id}), do: {"token", id}
  defp actor_fields(_), do: {nil, nil}

  # LIVE revoke signal (ag-liveview-read-liveness). A grantee sitting in a
  # mounted Studio desk holds a MOUNT-TIME grant snapshot in its socket assigns
  # (`:access_grants` + the grant-bearing `:caller_context`) — the read
  # row-narrowing (`Content.Scope.scope_to_grants`) reads that snapshot, so a
  # revoke would keep serving granted rows until the socket reconnected. Mirror
  # the mint-time `{:airdrop_granted}` push (`handlers/airdrop.ex`) with a
  # grantee-addressed `{:airdrop_revoked}` on the grantee's OWN user topic;
  # `StudioLive` handles it by reloading grants + rebuilding `caller_context` +
  # re-deriving caps, then re-running admission (a now-uncovered desk is killed).
  #
  # Only a CLAIMED grant has a bound `grantee_user_id` (an unclaimed grant has no
  # live socket to signal). Side-record only: broadcast to a local PubSub cannot
  # raise, but it is offered AFTER `Repo.update` succeeds and its result is
  # ignored, so it can never affect the revoke outcome.
  defp broadcast_revoked(%Grant{grantee_user_id: uid}) when is_binary(uid) do
    Phoenix.PubSub.broadcast(Barkpark.PubSub, "user:#{uid}", {:airdrop_revoked})
    :ok
  end

  defp broadcast_revoked(_grant), do: :ok

  # Audit metadata is a jsonb map hashed into the tamper-evident chain, whose
  # canonicaliser accepts only plain scalars/lists/maps — never a struct. So a
  # DateTime is serialised to an ISO8601 string (nil-safe), matching the
  # string-only convention of the other audit producers.
  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

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
