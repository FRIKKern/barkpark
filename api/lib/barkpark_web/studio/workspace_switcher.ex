defmodule BarkparkWeb.Studio.WorkspaceSwitcher do
  @moduledoc """
  Function component: the Sanity-style scope title + menu. The bar shows ONE
  button — the workspace name as the studio's title, with a muted
  `project / dataset` trail and a caret. Clicking it opens a single popover
  where workspace, project and dataset are picked together as three
  Miller columns (workspace → project → dataset), pre-focused on the
  current path.

  Column clicks PREVIEW (`scope-menu-ws` / `scope-menu-proj` reload the
  child columns without navigating); picking a dataset fires `scope-open`
  with the full (ws, proj, ds) triple — a `push_navigate` to the triple's
  canonical `/w/:ws/p/:proj/studio/:ds` URL (Scoped-by-URL: a scope pick
  IS a navigation). All events are handled by `BarkparkWeb.StudioChrome`'s
  hook on every chrome surface; menu state lives in the `:scope_menu`
  assign (nil = closed, see `StudioChrome.open_scope_menu/1` for the map).

  The create affordances ("+ New workspace" / "+ New project") live at the
  column feet and fire the same `toggle-create` / `create-*` events as
  before (StudioLive's in-socket handlers; the chrome's create-and-navigate
  fallback elsewhere). Project creation lands in the CURRENT workspace, so
  its affordance only renders while the previewed workspace IS the current
  one — never a "create here" trap under a merely-previewed tenant.
  """

  use Phoenix.Component

  import BarkparkWeb.Icons, only: [icon: 1]

  attr :current_workspace, :map, default: nil
  attr :current_project, :map, default: nil
  # The active dataset slug (the `/studio/:dataset` URL leaf) — shown muted
  # in the title trail and dotted as "current" in the dataset column.
  attr :current_dataset, :string, default: nil
  # The chrome's `:scope_menu` assign — nil (closed) or the menu-state map
  # (%{ws, proj, workspaces, projects, datasets}) built by StudioChrome.
  attr :menu, :map, default: nil
  # Whether the create affordances are shown. Creation needs an API token
  # (the owner principal); the handlers re-guard against forged events.
  attr :can_create, :boolean, default: false
  # Which inline create form is open: "workspace", "project", or nil.
  attr :create_open, :string, default: nil

  def switcher(assigns) do
    ~H"""
    <div
      class="scope-switcher"
      id="scope-switcher"
      phx-click-away={@menu && "scope-menu-close"}
      phx-window-keydown={@menu && "scope-menu-close"}
      phx-key={@menu && "escape"}
    >
      <button
        type="button"
        class="scope-title bar-focusable"
        phx-click="scope-menu-toggle"
        aria-haspopup="menu"
        aria-expanded={if @menu, do: "true", else: "false"}
        title="Switch workspace / project / dataset"
      >
        <span class="scope-title-ws"><%= name_of(@current_workspace) %></span>
        <span class="scope-title-trail">
          <%= name_of(@current_project) %> / <%= @current_dataset || "—" %>
        </span>
        <span class="scope-title-caret" aria-hidden="true"><.icon name="chevron-down" size={13} /></span>
      </button>

      <div :if={@menu} class="scope-menu" role="menu" aria-label="Switch workspace, project and dataset">
        <div class="scope-menu-col">
          <div class="scope-menu-col-title">Workspace</div>
          <div class="scope-menu-col-items">
            <button
              :for={ws <- @menu.workspaces}
              type="button"
              role="menuitem"
              class={[
                "scope-menu-item",
                same?(@menu.ws, ws) && "is-previewed",
                same?(@current_workspace, ws) && "is-current"
              ]}
              phx-click="scope-menu-ws"
              phx-value-id={ws.id}
            >
              <span class="scope-menu-item-name"><%= ws.name %></span>
              <span :if={same?(@current_workspace, ws)} class="scope-menu-dot" title="Current"></span>
            </button>
          </div>
          <%= if @can_create do %>
            <button
              type="button"
              class="scope-menu-create"
              phx-click="toggle-create"
              phx-value-target="workspace"
            >＋ New workspace</button>
            <form
              :if={@create_open == "workspace"}
              class="scope-menu-create-form"
              phx-submit="create-workspace"
            >
              <input
                type="text"
                name="name"
                class="workspace-switcher-create-input"
                placeholder="Workspace name"
                autocomplete="off"
                autofocus
              />
              <button type="submit" class="workspace-switcher-create-submit">Create</button>
            </form>
          <% end %>
        </div>

        <div class="scope-menu-col">
          <div class="scope-menu-col-title">Project</div>
          <div class="scope-menu-col-items">
            <span :if={@menu.projects == []} class="scope-menu-empty">No projects yet</span>
            <button
              :for={p <- @menu.projects}
              type="button"
              role="menuitem"
              class={[
                "scope-menu-item",
                same?(@menu.proj, p) && "is-previewed",
                same?(@current_project, p) && "is-current"
              ]}
              phx-click="scope-menu-proj"
              phx-value-id={p.id}
            >
              <span class="scope-menu-item-name"><%= p.name %></span>
              <span :if={same?(@current_project, p)} class="scope-menu-dot" title="Current"></span>
            </button>
          </div>
          <%= if @can_create and same?(@current_workspace, @menu.ws) do %>
            <button
              type="button"
              class="scope-menu-create"
              phx-click="toggle-create"
              phx-value-target="project"
            >＋ New project</button>
            <form
              :if={@create_open == "project"}
              class="scope-menu-create-form"
              phx-submit="create-project"
            >
              <input
                type="text"
                name="name"
                class="workspace-switcher-create-input"
                placeholder="Project name"
                autocomplete="off"
                autofocus
              />
              <button type="submit" class="workspace-switcher-create-submit">Create</button>
            </form>
          <% end %>
        </div>

        <div class="scope-menu-col">
          <div class="scope-menu-col-title">Dataset</div>
          <div class="scope-menu-col-items">
            <span :if={@menu.datasets == []} class="scope-menu-empty">No datasets</span>
            <button
              :for={ds <- @menu.datasets}
              type="button"
              role="menuitem"
              class={["scope-menu-item", current_dataset?(assigns, ds) && "is-current"]}
              phx-click="scope-open"
              phx-value-ws={@menu.ws && @menu.ws.slug}
              phx-value-proj={@menu.proj && @menu.proj.slug}
              phx-value-ds={ds.slug}
            >
              <span class="scope-menu-item-name"><%= ds.name %></span>
              <span :if={current_dataset?(assigns, ds)} class="scope-menu-dot" title="Current"></span>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp name_of(%{name: name}) when is_binary(name), do: name
  defp name_of(_), do: "—"

  defp same?(%{id: a}, %{id: b}), do: a == b
  defp same?(_, _), do: false

  # The dataset dot marks the page's ACTUAL location — only when the
  # previewed columns still sit on the current workspace + project.
  defp current_dataset?(assigns, ds) do
    same?(assigns.current_workspace, assigns.menu.ws) and
      same?(assigns.current_project, assigns.menu.proj) and
      ds.slug == assigns.current_dataset
  end
end
