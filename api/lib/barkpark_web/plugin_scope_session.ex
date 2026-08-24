defmodule BarkparkWeb.PluginScopeSession do
  @moduledoc """
  Bridges the resolved tenant scope across the HTTP→WebSocket boundary for
  the scoped plugin LiveViews mounted under
  `/w/:workspace_slug/p/:project_slug/{studio,admin}`, and CONFINES an
  anonymous item-share grant to its bound document on every socket mount.

  ## The boundary problem

  The `:scoped_browser` pipeline's `ResolveWorkspace` / `ResolveProject`
  plugs set `conn.assigns[:current_workspace]` / `[:current_project]`.
  Those assigns live on the HTTP conn only — they do NOT survive into the
  LiveView socket, which is established over a fresh WebSocket with just
  the session map. Without a bridge, `ScopeHelpers.scope_opts(socket)`
  reads empty `socket.assigns` and the plugin LV runs UNSCOPED past the
  membership gate.

  Two halves close the gap:

    * `build/1` — the `live_session :session` MFA. Phoenix calls it with
      the conn at dead-render time; it copies the resolved workspace /
      project **ids + slugs** out of `conn.assigns` into the session map.
      Only scalars cross — the full Ecto structs do not serialize into
      the signed session cookie cleanly, and `ScopeHelpers` only needs
      the id.

    * `on_mount/4` (`:scope`) — runs inside the LiveView mount. It reads
      those session keys back and puts `%{id: ...}`-shaped maps into
      `socket.assigns[:current_workspace]` / `[:current_project]`, the
      exact shape `ScopeHelpers.put_scope/3` pattern-matches. The LV then
      sees the real workspace scope.

  Fail-closed: `build/1` only emits keys that ResolveWorkspace/Project
  actually set. A non-member never reaches this MFA (ResolveWorkspace
  already 403'd), so the session never carries another workspace's scope.

  ## Item-share confinement (the socket re-mount seam)

  Scope is not the whole authorization story on the `:shared_paper_browser`
  pipeline. There, `BarkparkWeb.Plugs.RequireShareScope` can open an
  anonymous read through TWO different arms:

    * a SECTION share (`Barkpark.Sharing.shared?/4`) — grants the whole
      `(workspace, project, dataset, surface)` scope, so scope IS the grant;
    * an ITEM link (`?share=<token>`, `Barkpark.Sharing.Links`) — grants
      exactly ONE bound resource inside that scope.

  Both arms leave the identical conn assigns (`share_public: true`), and both
  make `ResolveWorkspace` skip its membership gate. The dead render is
  therefore correctly confined by the plug — but the plug runs on the HTTP
  conn only. A LiveView re-mounts over the ALREADY-ESTABLISHED WebSocket on
  `live_redirect` and on socket reconnect, replaying the SIGNED session
  against whatever URL the client asks for; no router pipeline runs on that
  join. An item-link holder could therefore hand the socket a sibling slug in
  the same live_session and read a paper the link never granted
  (task-9e74fdbdf0242c22).

  So this hook is not only a scope bridge: when the session records that the
  dead render was granted ANONYMOUSLY (`share_public`) and carries a raw item
  token, EVERY mount — first, live-navigated, or reconnected — re-resolves that
  token and requires it to bind the resource addressed by the CURRENT mount
  params. The bound resource comes from the SIGNED session's token, never from
  params, so a re-mount cannot re-choose it. Re-resolving (rather than baking
  the decision in at dead render) also means a REVOKED or EXPIRED link tears
  down on the next mount instead of living on in an already-open socket.

  Member mounts and section-share mounts are untouched: no `share_public` in
  the session (member) or no token in the session (section share) → `:cont`,
  byte-identical to before. The `:scoped_browser` live_sessions
  (`:scoped_plugin_admin` / `:scoped_plugin_public` / `:scoped_plugin_ops`)
  mount no `RequireShareScope`, so they never set `share_public` and this arm
  is inert for them.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias Barkpark.Sharing
  alias Barkpark.Sharing.Links

  @session_ws_id "scoped_workspace_id"
  @session_ws_slug "scoped_workspace_slug"
  @session_proj_id "scoped_project_id"
  @session_proj_slug "scoped_project_slug"

  # Item-share confinement keys (see the moduledoc). `@session_share_public`
  # records that the dead render was granted ANONYMOUSLY by RequireShareScope;
  # `@session_share_token` carries the RAW `?share=` item token so every mount
  # can re-resolve it (revocation + expiry are enforced inside that query).
  @session_share_public "scoped_share_public"
  @session_share_token "scoped_share_token"

  # The paper reader route carries no `/d/:dataset` segment, so the scoped
  # surface is the production dataset — the same default RequireShareScope
  # compares the link against.
  @default_dataset "production"

  # The `:shared_paper_browser` pipeline is the ONLY pipeline that pairs
  # `RequireShareScope` with a `PluginScopeSession` live_session, and it fixes
  # `surface: :papers`. That is the section-share surface a token-bearing mount
  # falls back to when its token does not bind the requested resource (a stale
  # or revoked `?share=` on a scope that is ALSO section-shared must keep
  # reading — narrowing the section-share path is explicitly out of scope for
  # this confinement).
  @section_surface :papers

  @doc """
  `live_session :session` MFA. Receives the HTTP conn; returns the extra
  session map merged into the LiveView session. Copies the resolved
  workspace/project ids + slugs from `conn.assigns`, plus the anonymous
  share-grant provenance the socket needs to re-confine an item link.
  Empty map when the resolvers didn't run (the assign is absent), so flat /
  unscoped mounts are unaffected.
  """
  def build(conn) do
    %{}
    |> put_scope(@session_ws_id, @session_ws_slug, conn.assigns[:current_workspace])
    |> put_scope(@session_proj_id, @session_proj_slug, conn.assigns[:current_project])
    |> put_share_grant(conn)
  end

  defp put_scope(acc, _id_key, _slug_key, nil), do: acc

  defp put_scope(acc, id_key, slug_key, %{id: id} = scope) do
    acc
    |> Map.put(id_key, id)
    |> Map.put(slug_key, Map.get(scope, :slug))
  end

  defp put_scope(acc, _id_key, _slug_key, _other), do: acc

  # Records the ANONYMOUS-grant provenance so the socket can re-run the
  # per-document decision the plug made on the conn. Only fires when
  # RequireShareScope actually granted (`share_public: true`); a member or
  # anonymous-Default dead render emits neither key, and the confinement arm
  # in `on_mount/4` stays inert.
  defp put_share_grant(acc, conn) do
    if conn.assigns[:share_public] == true do
      acc = Map.put(acc, @session_share_public, true)

      case share_query_token(conn) do
        raw when is_binary(raw) -> Map.put(acc, @session_share_token, raw)
        nil -> acc
      end
    else
      acc
    end
  end

  defp share_query_token(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.query_params["share"] do
      raw when is_binary(raw) and raw != "" -> raw
      _ -> nil
    end
  end

  defp share_query_token(_conn), do: nil

  @doc """
  `on_mount` hook. Reads the scope ids/slugs the `build/1` MFA wrote into
  the session and puts `%{id: ..., slug: ...}` maps into socket assigns
  under `:current_workspace` / `:current_project`. Absent keys → no assign
  (the LV stays unscoped, matching the flat back-compat surface).

  Halts ONLY on the item-share confinement arm (see the moduledoc): a session
  that records an ANONYMOUS item-token grant must re-prove, on EVERY mount,
  that the token binds the resource addressed by the current params. Member,
  section-share and unscoped mounts are never halted here — UI auth for those
  is the sibling `BarkparkWeb.LiveAuth` admin/ops on_mount hook.
  """
  def on_mount(:scope, params, session, socket) do
    socket =
      socket
      |> assign_scope(:current_workspace, session[@session_ws_id], session[@session_ws_slug])
      |> assign_scope(:current_project, session[@session_proj_id], session[@session_proj_slug])

    confine_item_share(params, session, socket)
  end

  defp assign_scope(socket, _key, nil, _slug), do: socket

  defp assign_scope(socket, key, id, slug) when is_binary(id) do
    assign(socket, key, %{id: id, slug: slug})
  end

  defp assign_scope(socket, _key, _id, _slug), do: socket

  # ── Item-share confinement ────────────────────────────────────────────────

  # Runs on EVERY mount of a live_session carrying this hook — the first mount,
  # a `live_redirect` re-mount over the open socket, and the mount that follows
  # a WebSocket reconnect. That is the point: none of those replay the router
  # pipeline, so the plug's per-resource check has to be re-derived here.
  defp confine_item_share(params, session, socket) do
    cond do
      # Membership-gated dead render (or an unscoped/flat mount): the scope IS
      # the grant, exactly as before this hook learned to halt.
      session[@session_share_public] != true ->
        {:cont, socket}

      # Anonymous grant with no item token → the SECTION-share arm granted the
      # whole scope. Deliberately untouched (`Sharing.shared?/4` semantics).
      is_nil(session[@session_share_token]) ->
        {:cont, socket}

      item_token_binds?(params, session) ->
        {:cont, socket}

      # A stale / foreign / revoked `?share=` on a scope that is ALSO
      # section-shared for `:papers` still reads — the token was never what
      # granted it, so confining on it would narrow the section-share path.
      section_shared?(session, params) ->
        {:cont, socket}

      true ->
        deny(socket)
    end
  end

  # Re-resolve the SIGNED session's raw token and require it to bind the
  # resource addressed by the CURRENT mount params, at the CURRENT scope.
  # `Links.resolve/1` enforces revocation + expiry in the query, so a link
  # revoked after the dead render fails here on the next mount.
  #
  # Socket twin of `BarkparkWeb.Plugs.RequireShareScope`'s conn-side check
  # (`maybe_grant_item_token/4` + `link_matches_route_resource?/2`). Kept local
  # rather than shared because the plug is fenced to a sibling lane this cycle;
  # unifying both onto one predicate is filed as follow-up work.
  defp item_token_binds?(params, session) when is_map(params) do
    with {:ok, link} <- Links.resolve(session[@session_share_token]),
         true <- link.workspace_id == session[@session_ws_id],
         true <- link.project_id == session[@session_proj_id],
         true <- link.dataset == (params["dataset"] || @default_dataset) do
      binds_route_resource?(link, params)
    else
      _ -> false
    end
  end

  # `:not_mounted_at_router` (or any non-map params) addresses no single
  # resource, and an item link can only ever open a single-resource route.
  defp item_token_binds?(_params, _session), do: false

  # Mirrors the plug's per-kind binding: paper reader → slug; doc read →
  # doc_id (compared exactly as minted); media → file id. Any other param
  # shape is NOT a single-resource route → never item-granted (fail closed).
  defp binds_route_resource?(link, %{"slug" => slug}),
    do: link.kind == "doc" and link.ref_type == "paper" and link.ref_id == slug

  defp binds_route_resource?(link, %{"doc_id" => doc_id}),
    do: link.kind == "doc" and link.ref_id == doc_id

  defp binds_route_resource?(link, %{"id" => id}),
    do: link.kind == "media" and link.ref_id == id

  defp binds_route_resource?(_link, _params), do: false

  defp section_shared?(session, params) when is_map(params),
    do: shared_for_dataset?(session, params["dataset"] || @default_dataset)

  defp section_shared?(session, _params), do: shared_for_dataset?(session, @default_dataset)

  defp shared_for_dataset?(session, dataset) do
    Sharing.shared?(
      session[@session_ws_slug],
      session[@session_proj_slug],
      dataset,
      @section_surface
    )
  end

  # Same denial envelope as the sibling socket gate `BarkparkWeb.LiveScope`:
  # a flash plus a FULL redirect out of the live_session — never a silent
  # in-socket fallback to another document.
  defp deny(socket) do
    {:halt,
     socket
     |> put_flash(:error, "That share link does not open this document")
     |> redirect(to: "/login")}
  end
end
