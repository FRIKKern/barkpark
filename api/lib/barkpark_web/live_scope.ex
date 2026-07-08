defmodule BarkparkWeb.LiveScope do
  @moduledoc """
  URL-scope resolution + re-authorization for the scoped Studio
  (`/w/:workspace_slug/p/:project_slug/d/:dataset/studio/...` — P1 of the
  Scoped-by-URL arc, design: `/papers/studio-url-architecture`).

  ## Why params, not the session

  The `:scoped_browser` conn pipeline (ResolveWorkspace/ResolveProject)
  gates the DEAD render only — plugs never run for live navigation, and a
  `live_session`'s session MFA is computed once at dead-render time
  (see `BarkparkWeb.PluginScopeSession`), so it goes stale the moment a
  `push_patch` moves the socket to another `/w/:ws`. URL params are the
  only truth that travels with live navigation. This hook therefore:

    * `on_mount(:resolve)` — resolves the workspace/project structs from
      the mount params, authorizes the socket's token (`:read`,
      membership-gated; anonymous fails closed), assigns
      `current_workspace` / `current_project` (full structs — StudioLive
      reads `.slug` and feeds `Tenancy.list_projects/1`) plus
      `scope_prefix` (`"/w/<ws>/p/<proj>"`, consumed by `studio_path`).

    * attaches a `handle_params` hook that RE-resolves and
      RE-authorizes whenever a patch lands with different scope slugs —
      the cross-tenant seam the conn pipeline cannot see. The hook runs
      before the LiveView's own `handle_params`, so StudioLive's
      `ensure_tenancy_scope` (leave-if-set) always finds the
      URL-resolved scope already in place.

  Fail-closed: unknown slugs, project not under the workspace, no token,
  or a token without membership+read all redirect to `/login` (full HTTP
  navigation — never a silent in-socket fallback to another tenant).
  The anonymous-Default allowance (public demo / dev no-login) arrives
  with the P3 cutover; the share-grant arm (read-only shared Studio)
  with P4.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, redirect: 2, put_flash: 3]

  alias Barkpark.Access
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy

  def on_mount(:resolve, params, _session, socket) do
    case resolve_and_authorize(socket, params) do
      {:ok, socket} ->
        {:cont, attach_hook(socket, :live_scope_reauth, :handle_params, &reauthorize/3)}

      {:halt, socket} ->
        {:halt, socket}
    end
  end

  # handle_params hook — only re-resolves when the URL's scope slugs differ
  # from the socket's current scope (same-scope patches are the hot path:
  # pane navigation, desk chips — zero extra queries for them).
  defp reauthorize(params, _uri, socket) do
    ws = socket.assigns[:current_workspace]
    proj = socket.assigns[:current_project]

    same_scope? =
      is_map(ws) and is_map(proj) and
        Map.get(ws, :slug) == params["workspace_slug"] and
        Map.get(proj, :slug) == params["project_slug"]

    if same_scope? do
      {:cont, socket}
    else
      case resolve_and_authorize(socket, params) do
        {:ok, socket} -> {:cont, socket}
        {:halt, socket} -> {:halt, socket}
      end
    end
  end

  defp resolve_and_authorize(
         socket,
         %{"workspace_slug" => ws_slug, "project_slug" => proj_slug} = params
       )
       when is_binary(ws_slug) and is_binary(proj_slug) do
    with %{} = ws <- Tenancy.get_workspace_by_slug(ws_slug),
         %{} = proj <- Tenancy.get_project(ws_slug, proj_slug),
         {:ok, grade} <- authorize_read(socket, ws, proj, params["dataset"]) do
      socket =
        socket
        |> assign(
          current_workspace: ws,
          current_project: proj,
          scope_prefix: "/w/#{ws.slug}/p/#{proj.slug}",
          share_access: if(grade == :share_read, do: :read, else: nil)
        )
        |> assign_grant_scope(grade)

      {:ok, maybe_attach_readonly_gate(socket, grade)}
    else
      _ -> deny(socket)
    end
  end

  defp resolve_and_authorize(socket, _params), do: deny(socket)

  # Membership + read permission via the canonical gate. Anonymous (nil
  # token) is allowed into: (a) the seeded Default workspace — the
  # socket-side mirror of ResolveWorkspace's :allow_anonymous_default
  # (P3, flat-parity demo/dev posture); or (b) a `:docs`-SHARED scope
  # (P4) — READ-ONLY, enforced by the handle_event gate this grade
  # attaches. Any other anonymous scope fails closed, and this arm is
  # what stops a LIVE patch from an authorized scope into a foreign one.
  defp authorize_read(socket, ws, proj, dataset) do
    case socket.assigns[:api_token] do
      %Barkpark.Auth.ApiToken{} = token ->
        case Tenancy.Auth.authorize(token, ws.id, :read) do
          :ok -> {:ok, :member}
          err -> err
        end

      _ ->
        # Access-grant admission (airdrop-grants ag-enforcement) — the socket
        # twin of ResolveWorkspace's grant path. Computed ONCE here (a DB load
        # of the user's active grants) and offered as the LAST cond clause.
        grant_ctx = grant_read_ctx(socket.assigns[:current_user], ws.id)

        cond do
          # studio-user-login: an account session (:current_user, set by
          # LiveAuth.:fetch_api_token) is a User principal — same authorize/3
          # chokepoint, the membership role is the grant. A signed-in user
          # WITHOUT a membership falls through to the anonymous allowances
          # below (signed in never grants less than anonymous).
          match?(%Barkpark.Accounts.User{}, socket.assigns[:current_user]) and
              Tenancy.Auth.authorize(socket.assigns[:current_user], ws.id, :read) == :ok ->
            {:ok, :member}

          # The Default demo allowance only while the public-demo flag is on
          # (studio-anonymous-default-lockdown — prod requires a sign-in;
          # flag-off falls through to the share arm, then deny → /login).
          Application.get_env(:barkpark, :public_demo_studio, false) and
              match?(%{id: id} when id == ws.id, Tenancy.get_default_workspace()) ->
            {:ok, :anonymous_default}

          Barkpark.Sharing.shared?(ws.slug, proj.slug, dataset || "production", :docs) ->
            {:ok, :share_read}

          # Grant arm, LAST before forbidden. ONLY a non-member signed-in USER
          # with an ACTIVE grant authorizing :read here (fail-closed nil ⇒ skip).
          # Ordered after the member / anonymous-default / share arms so a
          # grantee who ALSO qualifies for broader public access keeps it
          # UNNARROWED — grants only ADD access, never REMOVE it. The
          # grant-bearing ctx rides the grade → `scope_to_grants` narrows reads
          # to the grant ladder (via the :grant_scoped_read flag) and the write
          # gate is decided in `resolve_and_authorize`.
          not is_nil(grant_ctx) ->
            {:ok, {:grant, grant_ctx}}

          true ->
            {:error, :forbidden}
        end
    end
  end

  # Build a grant-bearing CallerContext for `user` and admit it ONLY if some
  # ACTIVE grant authorizes :read at this workspace. Returns the ctx (to ride
  # the grade) or nil. Verbatim port of ResolveWorkspace.grant_read_ctx/2 —
  # `from_user/2` loads active grants in-query; `Access.validate/3` applies
  # scope+capability+expiry. Fail-closed: no covering grant → nil.
  defp grant_read_ctx(%Barkpark.Accounts.User{id: uid}, workspace_id) when is_binary(uid) do
    ctx = CallerContext.from_user(uid)

    if Enum.any?(ctx.grants, fn grant ->
         Access.validate(grant, :read, %{workspace_id: workspace_id}) == :ok
       end) do
      ctx
    end
  end

  defp grant_read_ctx(_user, _workspace_id), do: nil

  # Read-only shared Studio (P4): a `:docs` read share opens the FULL
  # Studio UI to an anonymous viewer, so the write boundary must be the
  # SERVER's event handler, not hidden buttons. Deny-by-default: only
  # navigation/inspection events pass; everything else (autosave, save,
  # publish, delete, create, uploads, array ops, share admin, …) is
  # halted with a flash. The gate attaches once per mount of a
  # share-graded socket; member and anonymous-Default sockets never get it.
  @readonly_events ~w(
    select select-group select-desk select-pane
    switch-workspace switch-project switch-dataset
    scope-menu-toggle scope-menu-close scope-menu-ws scope-menu-proj scope-open
    jump-to-user show-profile preview-profile close-profile
    toggle-content-preview toggle-diff toggle-category
    editor-set-mode search ref-search validate-upload
  )

  defp maybe_attach_readonly_gate(socket, :share_read),
    do: attach_readonly_gate(socket, "This workspace is shared read-only")

  # Grant write-containment (airdrop-grants ag-enforcement). `scope_to_grants`
  # narrows READS only — Studio write handlers do not gate on :write. So a
  # grantee admitted via a read-only (or non-write) grant MUST have mutating
  # events denied by the same @readonly_events allowlist. A grantee whose grant
  # DOES confer :write at this workspace is NOT gated (their writes pass; row
  # narrowing still applies to reads). The write check is workspace-level
  # (`authorize(ctx, ws.id, :write)`) — a write-capable grantee writing OUTSIDE
  # their sub-scope is the reported residual, not gated here.
  defp maybe_attach_readonly_gate(socket, {:grant, ctx}) do
    ws = socket.assigns[:current_workspace]

    if Tenancy.Auth.authorize(ctx, ws.id, :write) == :ok do
      socket
    else
      attach_readonly_gate(socket, "Your access grant is read-only")
    end
  end

  defp maybe_attach_readonly_gate(socket, _grade), do: socket

  # Deny-by-default write gate: only @readonly_events pass; every mutating
  # event is halted with a flash. Idempotent across re-resolves (a live patch
  # re-runs this; attach_hook raises on a duplicate name). A stale gate that
  # later patches into a broader scope only over-restricts — never
  # under-restricts — so we keep it once attached.
  defp attach_readonly_gate(socket, message) do
    if socket.assigns[:readonly_gate?] do
      socket
    else
      socket
      |> assign(:readonly_gate?, true)
      |> attach_hook(:live_scope_readonly, :handle_event, fn event, _params, socket ->
        if event in @readonly_events do
          {:cont, socket}
        else
          {:halt, put_flash(socket, :error, message)}
        end
      end)
    end
  end

  # Assign the grant-bearing ctx + the row-narrowing flag for a grant-admitted
  # socket. `ScopeHelpers.scope_opts/1` reads both → threads `grant_scoped: true`
  # + the ctx into every read → `Content.Scope.scope_to_grants/3` narrows to the
  # grant ladder. Members / anonymous / share sockets are untouched (no flag,
  # no narrowing — byte-identical to today).
  defp assign_grant_scope(socket, {:grant, ctx}) do
    socket
    |> assign(:caller_context, ctx)
    |> assign(:grant_scoped_read, true)
  end

  defp assign_grant_scope(socket, _grade), do: socket

  defp deny(socket) do
    {:halt,
     socket
     |> put_flash(:error, "Not authorized for that workspace")
     |> redirect(to: "/login")}
  end
end
