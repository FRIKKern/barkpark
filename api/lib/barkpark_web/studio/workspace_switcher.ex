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

  def switcher(assigns) do
    workspaces = Tenancy.list_workspaces()

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
end
