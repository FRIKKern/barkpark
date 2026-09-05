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

  ## Liveness re-check on the OPEN socket (task-972d97ffd2e468d9)

  The re-resolve above still only ran at MOUNT time. A link revoked or
  expired after a reader's socket was already connected kept streaming that
  reader every PubSub update for the life of the socket — `/s/<token>` and a
  fresh dead render went dark immediately, but the already-open tab did not,
  which is not what an owner believes "revoke" buys them.

  So an item-share-granted CONNECTED mount (`Phoenix.LiveView.connected?/1` —
  a dead render schedules nothing) also arms a periodic re-check:
  `Process.send_after/3` schedules `@share_liveness_msg` to itself every
  `@share_liveness_interval_ms`, and `attach_hook/4` on `:handle_info`
  intercepts it, re-running the EXACT SAME `confine_item_share/3` predicate
  used at mount against the params/session captured at mount time. Success
  re-arms the timer; failure reuses `deny/1` — the same flash + full redirect
  a failed mount returns — which terminates the socket. Expiry needs no
  second mechanism: `Links.resolve/1` already filters `expires_at`, so the
  same re-check tears down an expired link too (proven by a dedicated test
  rather than assumed).

  The attached hook returns `{:cont, socket}` for every message that is not
  `@share_liveness_msg` — it must never intercept a foreign `handle_info`
  meant for the mounted LiveView itself.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [put_flash: 3, redirect: 2, connected?: 1, attach_hook: 4]

  alias Barkpark.Sharing
  alias Barkpark.Sharing.Links
  alias BarkparkWeb.PaperViewer

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

  # The ITEM LINK's own access level ("read" / "edit") as it stood at dead
  # render. Recorded so `BarkparkWeb.PaperViewer` can intersect it with the
  # LIVE row on every mount (slice 3, task-8ac4f3918da1c433) rather than trust
  # either half alone. It is NOT the enforcement point and never widens
  # anything: this hook still confines on the re-resolved token, and a session
  # claiming "edit" for a link since revoked or downgraded resolves to a
  # read-only viewer.
  @session_share_access "scoped_share_access"

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

  # Liveness re-check (see moduledoc). The message is namespaced by module so
  # a test can address it directly (`send(view.pid, {__MODULE__, :share_liveness_check})`)
  # without this module exporting anything new.
  @share_liveness_msg {__MODULE__, :share_liveness_check}
  @share_liveness_hook :plugin_scope_session_share_liveness

  # What the handle_info hook re-checks the item token against, stashed on
  # the socket at arm-time so the periodic callback needs no extra lookups.
  @share_liveness_assign :__plugin_scope_session_share_liveness__

  # 20s: honest about the exposure window (the row's complaint is an
  # UNBOUNDED socket, not merely a slow one) while staying well above one
  # PubSub tick, so a normal reader never pays for more than one re-resolve
  # per several document updates. Tens of seconds, not minutes.
  @share_liveness_interval_ms 20_000

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
        raw when is_binary(raw) ->
          acc
          |> Map.put(@session_share_token, raw)
          |> Map.put(@session_share_access, link_access_string(raw))

        nil ->
          acc
      end
    else
      acc
    end
  end

  # THE LINK's access, not `conn.assigns[:share_access]`.
  #
  # Those two are the same value only when the ITEM arm is what granted. On a
  # scope that is ALSO section-shared, `RequireShareScope`'s cond reaches
  # `grant_if_resolvable/4` first and grades the SECTION ("read"), and the
  # `?share=` token is never consulted — recording that grade here would
  # silently void an edit link on every section-shared scope.
  #
  # A STRING, not an atom: the session is a signed cookie and a string
  # round-trips with no atom-creation question. Anything that does not resolve
  # to an `access: "edit"` row records "read" — fail-closed.
  defp link_access_string(raw) do
    case Links.resolve(raw) do
      {:ok, %{access: "edit"}} -> "edit"
      _ -> "read"
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

    case confine_item_share(params, session, socket) do
      {:cont, socket} -> {:cont, maybe_arm_share_liveness(socket, params, session)}
      {:halt, socket} -> {:halt, socket}
    end
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

  # ── Open-socket liveness re-check (task-972d97ffd2e468d9) ──────────────────

  # Arms the periodic re-check ONLY for a CONNECTED, anonymously share-granted
  # mount — a dead render (`connected?/1` false) is re-derived fresh on every
  # HTTP request already and schedules nothing, and a member/unscoped mount
  # carries no `@session_share_public` so it never reaches here. The
  # already-stashed branch guards `attach_hook/4` (which raises on a duplicate
  # hook name) against `on_mount` somehow re-entering the SAME process; it
  # still refreshes the stashed params/session rather than no-op, so a second
  # entry can never re-arm against stale mount params.
  defp maybe_arm_share_liveness(socket, params, session) do
    cond do
      session[@session_share_public] != true ->
        socket

      not connected?(socket) ->
        socket

      match?(%{}, socket.assigns[@share_liveness_assign]) ->
        assign(socket, @share_liveness_assign, %{params: params, session: session})

      true ->
        Process.send_after(self(), @share_liveness_msg, @share_liveness_interval_ms)

        socket
        |> assign(@share_liveness_assign, %{params: params, session: session})
        |> attach_hook(@share_liveness_hook, :handle_info, &handle_share_liveness_info/2)
    end
  end

  # The hook itself. Re-runs the EXACT predicate mount uses, against the
  # params/session captured at arm-time, so a revoked or expired link tears
  # down an already-open socket instead of only failing the next mount.
  # MUST `{:cont, socket}` on every message that is not its own — this hook
  # is attached on every item-share-granted LiveView, so it must never
  # swallow a `handle_info` the mounted view itself expects.
  defp handle_share_liveness_info(@share_liveness_msg, socket) do
    %{params: params, session: session} = socket.assigns[@share_liveness_assign]

    case confine_item_share(params, session, socket) do
      {:cont, socket} ->
        socket = PaperViewer.refresh_share_capability(socket, session)
        Process.send_after(self(), @share_liveness_msg, @share_liveness_interval_ms)
        {:halt, socket}

      {:halt, socket} ->
        {:halt, socket}
    end
  end

  defp handle_share_liveness_info(_other, socket), do: {:cont, socket}

  # Re-resolve the SIGNED session's raw token and require it to bind the
  # resource addressed by the CURRENT mount params, at the CURRENT scope.
  # `Links.resolve/1` enforces revocation + expiry in the query, so a link
  # revoked after the dead render fails here on the next mount.
  #
  # Socket twin of `BarkparkWeb.Plugs.RequireShareScope`'s conn-side check
  # (`maybe_grant_item_token/4`). The per-resource binding is now decided by the
  # ONE owner both sides delegate to — `Links.binds_route_resource?/2`
  # (@canonical capability:share-link-route-binding) — so a kind added there
  # reaches the dead render and the socket mount together (task-3ba103f76393b04e).
  defp item_token_binds?(params, session) when is_map(params) do
    with {:ok, link} <- Links.resolve(session[@session_share_token]),
         true <- link.workspace_id == session[@session_ws_id],
         true <- link.project_id == session[@session_proj_id],
         true <- link.dataset == (params["dataset"] || @default_dataset) do
      Links.binds_route_resource?(link, params)
    else
      _ -> false
    end
  end

  # `:not_mounted_at_router` (or any non-map params) addresses no single
  # resource, and an item link can only ever open a single-resource route.
  defp item_token_binds?(_params, _session), do: false

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
