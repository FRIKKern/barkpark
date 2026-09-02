defmodule Barkpark.Sharing.Links do
  @moduledoc """
  ITEM sharing (P7) — Google-Docs-style direct links to ONE document or media
  file, minted and resolved WITHOUT a `Barkpark.Sharing` SECTION share.

  INDEPENDENT AT RESOLVE, SUBORDINATE AT REVOKE (arpss-w8, RULED CASCADE):
  `resolve/1` never consults `Sharing.shared?/4`, so a link works whether or not
  the scope is section-shared — but `Sharing.remove_share/3` calls
  `revoke_scope/3`, so removing the section share KILLS every live link under
  the same `(workspace, project, dataset)` triple. The older wording here said
  only "independent of SECTION shares", and reading it as independent in BOTH
  directions is what let a removed share leave `/s/<token>` URLs serving.

  A link is an opaque, revocable secret (`/s/<token>`) bound to a single item +
  its tenant scope + an access level (`read`/`edit`). `resolve/1` enforces
  revocation + expiry in the query, so a dead link looks identical to a missing
  one.

  THE RAW TOKEN IS STORED, unlike `Barkpark.Auth.ApiToken`: `create/1` writes
  BOTH `token_hash` and the PLAINTEXT `token`, because P7's stable re-copyable
  link needs a later read to re-emit `/s/<token>` (see
  `Barkpark.Sharing.ShareLink`). A ShareLink row is therefore a LIVE CREDENTIAL
  at rest and every read path that serialises one must be AUTHORISED BEFORE it
  serialises — arpss-w8 closed exactly that hole in
  `BarkparkWeb.ShareLinkController.list/2`. The older "returned once, only the
  SHA256 is stored" wording that stood here was false, and believing it is what
  made the leak look harmless.

  THIS CONTEXT OWNS TWO INVARIANTS THAT ITS CALLERS USED TO RE-DERIVE, because
  both doors onto the share surface (the HTTP controller and the Studio
  LiveView handler) reach `create/1` and `revoke/1` and each held only half:

    * `published_ref_id/1` — a link's `ref_id` is a PUBLISHED id. `create/1`
      applies it unconditionally, so no caller can persist a `drafts.`-prefixed
      ref. It used to live ONLY in `item_share.ex`'s first line, which meant the
      HTTP mint never had it (`arpss-w8-bl-share-link-drafts-ref-id`). It
      DELEGATES the rule to `Content.DraftId` rather than restating it.
    * `workspace_admin?/2` + `revoke_scoped/2` — the tenancy predicate, keyed on
      the LINK ROW's OWN `workspace_id`, never a caller-supplied scope. It used
      to be mirrored as a private helper in BOTH call sites
      (`arpss-w8-bl-links-context-boundary-predicate`).

  The predicate accepts an already-extracted PRINCIPAL (`%ApiToken{}`,
  `%User{}`, or a list to try in order) rather than a `%Plug.Conn{}` or a
  `%Phoenix.LiveView.Socket{}` — that is what lets one function serve both
  doors without this context learning about the web layer. Each call site
  extracts its own principal; only the AUTHORIZATION lives here.

  The CONTROLLER still owns existence validation at mint and the per-kind
  read/write dispatch at resolve.
  """
  import Ecto.Query

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.DraftId
  alias Barkpark.Repo
  alias Barkpark.Sharing.ShareLink
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # Cap the TTL at one year — mirrors Barkpark.Auth @share_token_max_ttl / the
  # share_controller "cap 1y" contract. A JSON-decoded bignum ttl would otherwise
  # drive DateTime.add into a runaway bignum date computation (request hang) or
  # mint an effectively never-expiring link, defeating expiry/revocation.
  @max_ttl 365 * 24 * 3600

  @doc "Hash a raw link token for storage/lookup (SHA256, like ApiToken)."
  @spec hash_token(binary()) :: binary()
  def hash_token(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  @doc """
  Strip a `drafts.` prefix so a ref_id names the PUBLISHED document.

  A share link is a PUBLIC, anonymous read surface, so its ref must never be a
  draft id. This is the SHARE SURFACE's single call site for that rule:
  `create/1` calls it on every write, `ShareLinkController` calls it before
  validating existence (so the mint validates the id it will actually store) and
  again when serving a row minted before this landed, and `ItemShare` calls it
  instead of the inline `String.replace_prefix/3` it used to carry.

  THE RULE ITSELF IS NOT REIMPLEMENTED HERE. It belongs to
  `Barkpark.Content.DraftId` (the leaf that owns the `drafts.` convention, and
  what `Content.published_id/1` delegates to); this function only adds the
  TOTALITY the share surface needs. `DraftId.published_id/1` raises on a
  non-binary, and `attrs` reaches `create/1` straight off a JSON body where
  `ref_id` may be absent, nil or a number — so a non-binary is returned
  UNCHANGED for the changeset's `validate_required` to reject as a 422, rather
  than raising a 500 out of the context.
  """
  @spec published_ref_id(term()) :: term()
  def published_ref_id(ref_id) when is_binary(ref_id), do: DraftId.published_id(ref_id)

  def published_ref_id(ref_id), do: ref_id

  @doc """
  Does this item link BIND the resource the CURRENT route addresses?

  ONE owner for the item-link route-binding decision. Two gates ask it, on the
  two sides of the HTTP→WebSocket boundary, and they MUST agree:

    * `BarkparkWeb.Plugs.RequireShareScope.maybe_grant_item_token/4` — the
      conn-side gate, passing `conn.path_params`;
    * `BarkparkWeb.PluginScopeSession.on_mount(:scope, …)` — the socket-side
      gate, passing the mount params, re-derived on EVERY mount because a
      `live_redirect` / reconnect replays no router pipeline
      (task-9e74fdbdf0242c22).

  They carried BYTE-IDENTICAL private copies until this promotion. The named
  failure mode (task-3ba103f76393b04e) is a kind — or a change to how a kind is
  compared — added to ONE copy: the dead render and the socket mount would then
  disagree about what a share link opens, and the socket is the half with no
  plug behind it. Adding a kind HERE reaches both, or neither.

  An item link is bound to ONE resource, so it opens only a route addressing
  exactly that resource:

    * `%{"slug" => slug}` — the paper reader → a `doc` link with
      `ref_type: "paper"` on that slug;
    * `%{"doc_id" => doc_id}` — a doc read → a `doc` link on that id, compared
      EXACTLY as minted. `published_ref_id/1` is deliberately NOT applied: a
      link is minted against a published id already, and canonicalising the
      ROUTE's id here would let `drafts.<id>` open the link bound to `<id>`.
    * `%{"id" => id}` — media meta/renditions → a `media` link on that file id.

  FAIL-CLOSED, and the clause ORDER is part of the contract. Any other params
  shape addresses no single resource (a list route, a file path,
  `:not_mounted_at_router`, or any non-map) and is never item-granted; and
  `slug` is decided BEFORE `doc_id`/`id`, so a params map carrying two of them
  (the socket side is handed the MERGED mount params, not path params alone)
  cannot be opened by the looser of the two.
  """
  @spec binds_route_resource?(ShareLink.t(), term()) :: boolean()
  # @canonical capability:share-link-route-binding aka:item link binding,ref_id match,link_matches_route_resource
  def binds_route_resource?(link, %{"slug" => slug}),
    do: link.kind == "doc" and link.ref_type == "paper" and link.ref_id == slug

  def binds_route_resource?(link, %{"doc_id" => doc_id}),
    do: link.kind == "doc" and link.ref_id == doc_id

  def binds_route_resource?(link, %{"id" => id}),
    do: link.kind == "media" and link.ref_id == id

  def binds_route_resource?(_link, _params), do: false

  @doc """
  Is `principal` an ADMIN MEMBER of `workspace_id`?

  `principal` is an already-extracted `%ApiToken{}` / `%User{}`, or a LIST of
  candidates (a Studio socket can carry both an api_token session and a
  logged-in account; either may legitimately hold the seat).

  TOTALITY: bare `TenancyAuth.workspace_admin?/2` RAISES on most shapes that can
  reach here — `FunctionClauseError` on a nil principal, an `%ApiToken{id: nil}`
  or a nil workspace id, and `Ecto.Query.CastError` on `""` / any non-UUID
  binary. Both sides are narrowed first and ANYTHING unmatched is a DENIAL: a
  500 here would trade a leak for a crash oracle.

  The predicate is `workspace_admin?/2` (the membership ROLE), NEVER
  `TenancyAuth.authorize/3` — authorize/3's api_token arm ORs the token's GLOBAL
  `permissions[]` with membership, so a plain `member` of workspace B holding
  global `admin` perms would PASS it. That actor is exactly the attacker in the
  committed cross-tenant tests, so swapping the call turns them RED.
  """
  @spec workspace_admin?(term(), term()) :: boolean()
  def workspace_admin?(principal, workspace_id) do
    case Repo.uuid_or_nil(workspace_id) do
      nil -> false
      ws_id -> principal_admin?(principal, ws_id)
    end
  end

  defp principal_admin?(principals, ws_id) when is_list(principals),
    do: Enum.any?(principals, &principal_admin?(&1, ws_id))

  defp principal_admin?(%ApiToken{id: id} = token, ws_id) when is_binary(id),
    do: TenancyAuth.workspace_admin?(token, ws_id)

  defp principal_admin?(%User{id: id} = user, ws_id) when is_binary(id),
    do: TenancyAuth.workspace_admin?(user, ws_id)

  defp principal_admin?(_principal, _ws_id), do: false

  @doc """
  Revoke a link only when `principal` administers the link ROW's OWN workspace.

  DENIAL SHAPE: a non-castable id, a missing row, a foreign row, and a row with
  a nil `workspace_id` ALL collapse to the same `{:error, :not_found}`, so a
  caller's 404 arm is ONE call site and a foreign row is byte-identical to a
  missing one. No existence oracle, and no 500 from an uncast `:binary_id`.

  `revoke/1` keeps its arity and its unauthorized behaviour: it has non-HTTP
  callers with no actor to authorize. Anything reachable by a REQUEST should
  call this instead.
  """
  @spec revoke_scoped(term(), term()) :: {:ok, ShareLink.t()} | {:error, :not_found}
  def revoke_scoped(principal, id) do
    with row_id when is_binary(row_id) <- Repo.uuid_or_nil(id),
         %ShareLink{workspace_id: ws_id} <- Repo.get(ShareLink, row_id),
         true <- workspace_admin?(principal, ws_id) do
      revoke(row_id)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Create an item link. `attrs` must carry `:workspace_id`, `:project_id`,
  `:dataset`, `:kind` (`"doc"`/`"media"`), `:ref_id`, `:access`; `:ref_type`
  for docs; optional `:label`, `:ttl` (seconds — omit / nil for no expiry).
  Returns `{:ok, {raw_token, %ShareLink{}}}`. The raw token is ALSO persisted on
  the row (see the moduledoc), so this is not a show-once secret.
  """
  @spec create(map()) :: {:ok, {binary(), ShareLink.t()}} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    raw = generate_token()

    expires_at =
      case attrs[:ttl] || attrs["ttl"] do
        ttl when is_integer(ttl) and ttl > 0 ->
          DateTime.utc_now()
          |> DateTime.add(min(ttl, @max_ttl), :second)
          |> DateTime.truncate(:second)

        _ ->
          nil
      end

    # THE CLAMP, applied at the boundary BOTH doors cross rather than at either
    # of them: whichever key the caller used, the persisted ref names the
    # published document. Patching only one door is the defect this repairs.
    row_attrs =
      attrs
      |> Map.drop([:ttl, "ttl"])
      |> Map.put(:token_hash, hash_token(raw))
      |> Map.put(:token, raw)
      |> Map.put(:expires_at, expires_at)
      |> normalize_ref_id()

    %ShareLink{}
    |> ShareLink.changeset(row_attrs)
    |> Repo.insert()
    |> case do
      {:ok, link} -> {:ok, {raw, link}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Resolve a raw token to its ACTIVE link (not revoked, not expired). Returns
  `{:ok, %ShareLink{}}` or `{:error, :not_found}` — no existence leak between
  missing / revoked / expired.
  """
  @spec resolve(term()) :: {:ok, ShareLink.t()} | {:error, :not_found}
  def resolve(raw) when is_binary(raw) and raw != "" do
    hash = hash_token(raw)
    now = DateTime.utc_now()

    ShareLink
    |> where([l], l.token_hash == ^hash)
    |> where([l], is_nil(l.revoked_at))
    |> where([l], is_nil(l.expires_at) or l.expires_at > ^now)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      link -> {:ok, link}
    end
  end

  def resolve(_), do: {:error, :not_found}

  @doc """
  THE CASCADE — revoke every live link minted under one SECTION-share scope.

  Called by `Barkpark.Sharing.remove_share/3`, which is the only place an
  operator can withdraw a section share. RULED CASCADE (lead-security-r,
  2026-09-02): item links derive their authority from the share they were
  minted under, so they fall with it. Revocation is fail-closed — a link that
  outlives the share it came from is a leak the operator cannot see.

  Takes SLUGS, mirroring `Barkpark.Auth.revoke_share_tokens/3` so the two
  revocations at that one call site read the same. The rows key on tenant UUIDs,
  so the slugs are resolved here; that keeps `Barkpark.Sharing` free of any
  Tenancy dependency.

  MATCHES THE TRIPLE EXACTLY, never a prefix: a link in a sibling project or a
  sibling dataset is in a DIFFERENT scope and survives untouched. An
  unresolvable workspace or project revokes nothing (`{:ok, 0}`) — both mint
  doors resolve real ids, so no link can be bound to a tenant that is not there.
  Already-revoked rows keep their original `revoked_at`. Never raises.
  """
  @spec revoke_scope(term(), term(), term()) :: {:ok, non_neg_integer()}
  def revoke_scope(ws_slug, proj_slug, dataset)
      when is_binary(ws_slug) and is_binary(proj_slug) and is_binary(dataset) do
    with %Tenancy.Workspace{id: ws_id} <- Tenancy.get_workspace_by_slug(ws_slug),
         %Tenancy.Project{id: proj_id} <- Tenancy.get_project(ws_slug, proj_slug) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {count, _} =
        ShareLink
        |> where([l], l.workspace_id == ^ws_id and l.project_id == ^proj_id)
        |> where([l], l.dataset == ^dataset)
        |> where([l], is_nil(l.revoked_at))
        |> Repo.update_all(set: [revoked_at: now])

      {:ok, count}
    else
      _ -> {:ok, 0}
    end
  end

  def revoke_scope(_ws_slug, _proj_slug, _dataset), do: {:ok, 0}

  @doc "Revoke (stamp `revoked_at`) one link by id. Idempotent."
  @spec revoke(binary()) :: {:ok, ShareLink.t()} | {:error, :not_found}
  def revoke(id) when is_binary(id) do
    # Guard the :binary_id cast — a non-UUID id (from `DELETE /v1/shares/links/
    # garbage`) would raise Ecto.CastError → 500; treat it as not_found instead.
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(ShareLink, uuid) do
          nil ->
            {:error, :not_found}

          link ->
            link
            |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
            |> Repo.update()
        end
    end
  end

  @doc """
  List the links for ONE item (newest first). RETURNS LIVE CREDENTIALS: each row
  carries the PLAINTEXT `token` (and its hash), so a caller must be authorised
  against `workspace_id` BEFORE it serialises anything this returns — the raw is
  NOT unrecoverable. `ref_type` may be nil (media).
  """
  @spec list_for(binary(), binary(), binary() | nil, binary()) :: [ShareLink.t()]
  def list_for(workspace_id, kind, ref_type, ref_id) do
    ShareLink
    |> where([l], l.workspace_id == ^workspace_id and l.kind == ^kind and l.ref_id == ^ref_id)
    |> ref_type_filter(ref_type)
    |> order_by([l], desc: l.inserted_at)
    |> Repo.all()
  end

  # `attrs` reaches create/1 with either atom or string keys depending on the
  # door, so both are normalised; a map carrying neither is left alone for the
  # changeset to reject.
  defp normalize_ref_id(%{ref_id: ref} = attrs),
    do: Map.put(attrs, :ref_id, published_ref_id(ref))

  defp normalize_ref_id(%{"ref_id" => ref} = attrs),
    do: Map.put(attrs, "ref_id", published_ref_id(ref))

  defp normalize_ref_id(attrs), do: attrs

  defp ref_type_filter(query, nil), do: where(query, [l], is_nil(l.ref_type))
  defp ref_type_filter(query, ref_type), do: where(query, [l], l.ref_type == ^ref_type)

  # 24 bytes → 32 url-safe chars. Opaque; the link is the only authorization.
  defp generate_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
