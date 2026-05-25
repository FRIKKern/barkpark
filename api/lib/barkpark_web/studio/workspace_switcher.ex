defmodule BarkparkWeb.Studio.WorkspaceSwitcher do
  @moduledoc """
  Function component: renders the active scope as three left→right controls —
  **Workspace · Project · Dataset**. The first two switch a LiveView event (not
  a `window.location` navigation): the Studio route shape stays `/studio/:dataset`,
  so workspace/project scope lives on the socket. The Dataset (the rightmost
  control) IS the URL leaf — switching it re-scopes via `switch-dataset`, which
  `push_patch`es to `/studio/:new_dataset`.

  Auto-set (Task barkpark-dgpf): on mount the switcher comes up with the resolved
  workspace + project + dataset already selected (the Default / member scope
  `ensure_tenancy_scope/1` and `handle_params` seed) — never a bare placeholder.
  When a level has exactly ONE option it renders as a plain non-interactive
  label (static text), not a one-option dropdown; multiple options render a
  `<select>` defaulting to the current.

  Dataset is bound to the PROJECT: its options are `Tenancy.list_datasets/1` of
  the current project (the `%Dataset{}` rows), `selected` = the current dataset
  slug. When the project changes, StudioLive's `switch-project` handler reloads
  this list and auto-selects the project's default dataset (a "production" slug
  if present, else the first), then re-scopes to it.

  Re-scoping the URL under `/w/:ws/p/:project` is a separate task
  (barkpark-4tuu) — this component does NOT touch the route prefix.
  """

  use Phoenix.Component

  alias Barkpark.Tenancy

  attr :current_workspace, :map, default: nil
  attr :current_project, :map, default: nil
  # The active dataset slug (the `/studio/:dataset` URL leaf). The Dataset
  # select's options come from the CURRENT project's datasets, with this slug
  # marked selected. nil/unknown falls through to no pre-selection.
  attr :current_dataset, :string, default: nil
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

    # `current_project` can be a `%Project{}` struct OR a bare scope map
    # (e.g. the scoped-plugin LV assigns `%{id: …, slug: …}`), so resolve
    # datasets by the project id — `list_datasets/1`'s binary clause — rather
    # than pattern-matching a struct. A nil/idless project yields no datasets.
    datasets =
      case assigns[:current_project] do
        %{id: id} when is_binary(id) -> Tenancy.list_datasets(id)
        _ -> []
      end

    assigns =
      assigns
      |> assign(:workspaces, workspaces)
      |> assign(:projects, projects)
      |> assign(:datasets, datasets)

    ~H"""
    <label class="workspace-switcher">
      <span class="workspace-switcher-label">Workspace</span>
      <%= if length(@workspaces) <= 1 do %>
        <span class="workspace-switcher-static"><%= current_label(@current_workspace, @workspaces) %></span>
      <% else %>
        <select class="workspace-switcher-select" phx-change="switch-workspace" name="workspace">
          <%= for ws <- @workspaces do %>
            <option value={ws.slug} selected={selected?(@current_workspace, ws)}>
              <%= ws.name %>
            </option>
          <% end %>
        </select>
      <% end %>
    </label>
    <label class="workspace-switcher">
      <span class="workspace-switcher-label">Project</span>
      <%= if length(@projects) <= 1 do %>
        <span class="workspace-switcher-static"><%= current_label(@current_project, @projects) %></span>
      <% else %>
        <select class="workspace-switcher-select" phx-change="switch-project" name="project">
          <%= for p <- @projects do %>
            <option value={p.slug} selected={selected?(@current_project, p)}>
              <%= p.name %>
            </option>
          <% end %>
        </select>
      <% end %>
    </label>
    <label class="dataset-switcher">
      <span class="dataset-switcher-label">Dataset</span>
      <%= if length(@datasets) <= 1 do %>
        <span class="dataset-switcher-static"><%= dataset_label(@current_dataset, @datasets) %></span>
      <% else %>
        <select class="dataset-switcher-select" phx-change="switch-dataset" name="dataset">
          <%= for ds <- @datasets do %>
            <option value={ds.slug} selected={ds.slug == @current_dataset}>
              <%= ds.name %>
            </option>
          <% end %>
        </select>
      <% end %>
    </label>
    """
  end

  defp selected?(%{slug: current_slug}, %{slug: slug}), do: current_slug == slug
  defp selected?(_, _), do: false

  # Static-label text for a single-option (or no-option) workspace/project
  # level. Prefer the current selection's name; fall back to the sole option;
  # last-resort an em-dash so the chrome never renders an empty label.
  defp current_label(%{name: name}, _options) when is_binary(name), do: name
  defp current_label(_, [%{name: name} | _]) when is_binary(name), do: name
  defp current_label(_, _), do: "—"

  # Static-label text for a single-option (or no-option) dataset level. Prefer
  # the matching dataset row's name; fall back to the current slug; then the
  # sole option; last-resort em-dash.
  defp dataset_label(current_slug, datasets) when is_binary(current_slug) do
    case Enum.find(datasets, &(&1.slug == current_slug)) do
      %{name: name} -> name
      _ -> current_slug
    end
  end

  defp dataset_label(_, [%{name: name} | _]) when is_binary(name), do: name
  defp dataset_label(_, _), do: "—"

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
