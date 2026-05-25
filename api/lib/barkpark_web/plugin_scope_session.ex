defmodule BarkparkWeb.PluginScopeSession do
  @moduledoc """
  Bridges the resolved tenant scope across the HTTP→WebSocket boundary for
  the scoped plugin LiveViews mounted under
  `/w/:workspace_slug/p/:project_slug/{studio,admin}`.

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
  """

  import Phoenix.Component, only: [assign: 3]

  @session_ws_id "scoped_workspace_id"
  @session_ws_slug "scoped_workspace_slug"
  @session_proj_id "scoped_project_id"
  @session_proj_slug "scoped_project_slug"

  @doc """
  `live_session :session` MFA. Receives the HTTP conn; returns the extra
  session map merged into the LiveView session. Copies the resolved
  workspace/project ids + slugs from `conn.assigns`. Empty map when the
  resolvers didn't run (the assign is absent), so flat / unscoped mounts
  are unaffected.
  """
  def build(conn) do
    %{}
    |> put_scope(@session_ws_id, @session_ws_slug, conn.assigns[:current_workspace])
    |> put_scope(@session_proj_id, @session_proj_slug, conn.assigns[:current_project])
  end

  defp put_scope(acc, _id_key, _slug_key, nil), do: acc

  defp put_scope(acc, id_key, slug_key, %{id: id} = scope) do
    acc
    |> Map.put(id_key, id)
    |> Map.put(slug_key, Map.get(scope, :slug))
  end

  defp put_scope(acc, _id_key, _slug_key, _other), do: acc

  @doc """
  `on_mount` hook. Reads the scope ids/slugs the `build/1` MFA wrote into
  the session and puts `%{id: ..., slug: ...}` maps into socket assigns
  under `:current_workspace` / `:current_project`. Absent keys → no assign
  (the LV stays unscoped, matching the flat back-compat surface).

  Never halts — UI auth is the sibling `BarkparkWeb.LiveAuth` admin/ops
  on_mount hook; this hook only carries the already-gated scope through.
  """
  def on_mount(:scope, _params, session, socket) do
    socket =
      socket
      |> assign_scope(:current_workspace, session[@session_ws_id], session[@session_ws_slug])
      |> assign_scope(:current_project, session[@session_proj_id], session[@session_proj_slug])

    {:cont, socket}
  end

  defp assign_scope(socket, _key, nil, _slug), do: socket

  defp assign_scope(socket, key, id, slug) when is_binary(id) do
    assign(socket, key, %{id: id, slug: slug})
  end

  defp assign_scope(socket, _key, _id, _slug), do: socket
end
