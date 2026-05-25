defmodule BarkparkWeb.Studio.WorkspaceSwitcher do
  @moduledoc """
  Function component: renders two `<select>`s — the active Workspace and,
  within it, the active Project. Mirrors `DatasetSwitcher`'s chrome, but
  switching is a LiveView event (not a `window.location` navigation): the
  Studio route shape stays `/studio/:dataset`, so the workspace/project scope
  lives on the socket. Selecting a workspace fires `phx-change="switch-workspace"`;
  selecting a project fires `phx-change="switch-project"`. StudioLive's handlers
  re-assign `:current_workspace` / `:current_project` and re-load the desk.

  Re-scoping the URL under `/w/:ws/p/:project` is a separate task
  (barkpark-4tuu) — this component does NOT touch the route prefix.
  """

  use Phoenix.Component

  alias Barkpark.Tenancy

  attr :current_workspace, :map, default: nil
  attr :current_project, :map, default: nil
  # The mounted principal (an `%ApiToken{}` or nil). The hard tenant boundary:
  # the workspace `<select>` lists ONLY the workspaces this principal is a
  # member of (`Tenancy.list_workspaces_for/1` INNER-JOINs membership), never
  # the unscoped `list_workspaces/0`. A nil principal yields `[]` — but so the
  # genuinely-anonymous single-tenant dev case never loses its current
  # selection, the current workspace is unioned in when present (it was set
  # from the Default backfill in `ensure_tenancy_scope/1`).
  attr :principal, :any, default: nil

  def switcher(assigns) do
    workspaces =
      assigns[:principal]
      |> Tenancy.list_workspaces_for()
      |> ensure_current(assigns[:current_workspace])

    projects =
      case assigns[:current_workspace] do
        %{id: ws_id} -> Tenancy.list_projects(ws_id)
        _ -> []
      end

    assigns =
      assigns
      |> assign(:workspaces, workspaces)
      |> assign(:projects, projects)

    ~H"""
    <label class="workspace-switcher">
      <span class="workspace-switcher-label">Workspace</span>
      <select class="workspace-switcher-select" phx-change="switch-workspace" name="workspace">
        <%= for ws <- @workspaces do %>
          <option value={ws.slug} selected={selected?(@current_workspace, ws)}>
            <%= ws.name %>
          </option>
        <% end %>
      </select>
    </label>
    <label class="workspace-switcher">
      <span class="workspace-switcher-label">Project</span>
      <select class="workspace-switcher-select" phx-change="switch-project" name="project">
        <%= for p <- @projects do %>
          <option value={p.slug} selected={selected?(@current_project, p)}>
            <%= p.name %>
          </option>
        <% end %>
      </select>
    </label>
    """
  end

  defp selected?(%{slug: current_slug}, %{slug: slug}), do: current_slug == slug
  defp selected?(_, _), do: false

  # Keep the active workspace visible in the dropdown even when it isn't in the
  # membership list — the anonymous/dev case seeds `current_workspace` from the
  # Default backfill (no membership row). This never exposes a FOREIGN
  # workspace: only the one already on the socket, which the switch-workspace
  # gate independently re-checks. Members see their real list; the dev session
  # keeps Default. Re-sorted by slug so order matches `list_workspaces_for/1`.
  defp ensure_current(workspaces, %{id: id} = current) do
    if Enum.any?(workspaces, &(&1.id == id)) do
      workspaces
    else
      Enum.sort_by([current | workspaces], & &1.slug)
    end
  end

  defp ensure_current(workspaces, _), do: workspaces
end
