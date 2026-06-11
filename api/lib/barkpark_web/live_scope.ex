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
        assign(socket,
          current_workspace: ws,
          current_project: proj,
          scope_prefix: "/w/#{ws.slug}/p/#{proj.slug}",
          share_access: if(grade == :share_read, do: :read, else: nil)
        )

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
        cond do
          match?(%{id: id} when id == ws.id, Tenancy.get_default_workspace()) ->
            {:ok, :anonymous_default}

          Barkpark.Sharing.shared?(ws.slug, proj.slug, dataset || "production", :docs) ->
            {:ok, :share_read}

          true ->
            {:error, :forbidden}
        end
    end
  end

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

  defp maybe_attach_readonly_gate(socket, :share_read) do
    # Idempotent across re-resolves (a live patch between two shared scopes
    # re-runs this; attach_hook raises on a duplicate name). A stale gate on
    # an anonymous socket that later patches into the Default scope only
    # over-restricts — never under-restricts — so we keep it once attached.
    if socket.assigns[:readonly_gate?] do
      socket
    else
      socket
      |> assign(:readonly_gate?, true)
      |> attach_hook(:live_scope_readonly, :handle_event, fn event, _params, socket ->
        if event in @readonly_events do
          {:cont, socket}
        else
          {:halt, put_flash(socket, :error, "This workspace is shared read-only")}
        end
      end)
    end
  end

  defp maybe_attach_readonly_gate(socket, _grade), do: socket

  defp deny(socket) do
    {:halt,
     socket
     |> put_flash(:error, "Not authorized for that workspace")
     |> redirect(to: "/login")}
  end
end
