defmodule Barkpark.Plugins.Tasks.Web.ListLive do
  @moduledoc """
  The Tasks list: every task in a table, with search, filters, sorting and
  paging. It sits beside the board at `/admin/projects/list`.

  The board shows work in motion and keeps only the newest 12 done tasks on
  screen. This page is where a person finds an old, closed or cancelled task.
  A row opens the board's own task detail (`/admin/projects?task=<id>`).

  ## Access

  The same rules as the board (`Barkpark.Plugins.Tasks.Web.BoardLive`):

    * the route is declared `auth: :ops` next to the board's;
    * `mount/3` runs `BarkparkWeb.OpsOperatorGate.mount/2`, so the flat mount
      takes the instance operator only and a token bound to another dataset is
      turned away;
    * every `handle_params/3` checks the gate again and reads the scope again,
      because a patch link reaches it without passing the gate's event hook;
    * the flat mount reads every workspace, a scoped mount reads its own;
    * fields go through `Barkpark.Tasks.Board.field_visibility_gate/1`, the
      board's fail-closed predicate (see `ListQuery` for what it hides).

  ## State

  The URL holds all of it (`q`, `status`, `priority`, `assignee`, `label`,
  `parent`, `sort`, `dir`, `page`). Every control patches the URL and
  `handle_params/3` runs the read, so a view can be shared and the back button
  works. The page does not subscribe to task events; reload to see new writes.

  The strings are English only, like the board's.
  """

  use BarkparkWeb, :live_view

  alias Barkpark.Plugins.Tasks.Web.ListQuery
  alias Barkpark.Plugins.Tasks.Web.ListStyles
  alias Barkpark.Tasks.Board
  alias BarkparkWeb.OpsOperatorGate

  @dataset "production"

  @refusal "This screen spans every workspace and is reserved for the instance operator. " <>
             "Open it from inside your workspace instead."

  @doc "The list's path for a board URL: the board's own path plus `/list`."
  @spec list_path(String.t()) :: String.t()
  def list_path(board_uri) when is_binary(board_uri) do
    String.trim_trailing(URI.parse(board_uri).path || "/admin/projects", "/") <> "/list"
  end

  @impl true
  def mount(_params, session, socket) do
    case OpsOperatorGate.mount(socket, session) do
      {:ok, socket} ->
        {:ok,
         socket
         |> assign(:loading, true)
         |> assign(:path, "/admin/projects/list")
         |> assign(:board_path, "/admin/projects")}

      {:halt, socket} ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    path = String.trim_trailing(URI.parse(uri).path, "/")

    socket =
      socket
      |> assign(:path, path)
      |> assign(:board_path, String.replace_suffix(path, "/list", ""))

    cond do
      # The dead render is thrown away on connect; it reads nothing.
      not connected?(socket) ->
        {:noreply, socket}

      not permitted?(socket) ->
        {:noreply, socket |> put_flash(:error, @refusal) |> redirect(to: "/studio")}

      true ->
        {:noreply, load(socket, params)}
    end
  end

  # A scoped mount was admitted by `ResolveWorkspace` for its workspace. The
  # flat mount must still be the instance operator on every read.
  defp permitted?(socket) do
    is_binary(OpsOperatorGate.scoped_workspace_id(socket)) or
      OpsOperatorGate.flat_operator?(socket)
  end

  defp load(socket, params) do
    readable? = Board.field_visibility_gate(@dataset)
    filters = ListQuery.parse(params, readable?)

    result =
      ListQuery.page(filters,
        dataset: @dataset,
        workspace_id: OpsOperatorGate.scoped_workspace_id(socket),
        readable?: readable?
      )

    socket
    |> assign(:loading, false)
    |> assign(:filters, %{filters | page: result.page})
    |> assign(:result, result)
    |> assign(:can, %{
      priority: readable?.("priority"),
      worker: readable?.("assignee") and readable?.("claim"),
      labels: readable?.("labels"),
      parent: readable?.("parent_id")
    })
  end

  # ── events: each one only rewrites the URL ──────────────────────────────────

  @impl true
  def handle_event("filter", params, socket) do
    f = socket.assigns.filters

    parent =
      case {String.trim(params["parent"] || ""), f.parent} do
        {"", :none} -> "none"
        {typed, _} -> typed
      end

    changes = %{
      "q" => params["q"] || "",
      "assignee" => params["assignee"] || f.assignee,
      "label" => params["label"] || f.label,
      "parent" => parent
    }

    {:noreply, patch(socket, changes)}
  end

  def handle_event("toggle-status", %{"value" => value}, socket) do
    {:noreply, patch(socket, %{"status" => toggle(socket.assigns.filters.statuses, value)})}
  end

  def handle_event("toggle-priority", %{"value" => value}, socket) do
    {:noreply, patch(socket, %{"priority" => toggle(socket.assigns.filters.priorities, value)})}
  end

  def handle_event("toggle-no-parent", _params, socket) do
    next = if socket.assigns.filters.parent == :none, do: "", else: "none"
    {:noreply, patch(socket, %{"parent" => next})}
  end

  def handle_event("clear-filters", _params, socket) do
    {:noreply, push_patch(socket, to: socket.assigns.path)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp toggle(current, value) when is_binary(value) do
    next = if value in current, do: List.delete(current, value), else: current ++ [value]
    Enum.join(next, ",")
  end

  # A changed filter starts again at page 1. `handle_params/3` parses and
  # whitelists what lands in the URL; nothing here is trusted.
  defp patch(socket, changes) do
    push_patch(socket, to: href(socket.assigns.path, socket.assigns.filters, changes))
  end

  defp href(path, filters, changes) do
    query =
      filters
      |> ListQuery.to_params()
      |> Map.new()
      |> Map.delete("page")
      |> Map.merge(changes)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.sort()

    if query == [], do: path, else: path <> "?" <> URI.encode_query(query)
  end

  defp page_href(path, filters, page) do
    query = filters |> Map.put(:page, page) |> ListQuery.to_params()
    if query == [], do: path, else: path <> "?" <> URI.encode_query(query)
  end

  # A header click sorts by that column; a second click flips the direction.
  defp sort_href(path, filters, sort) do
    dir =
      cond do
        filters.sort != sort -> ListQuery.default_dir(sort)
        filters.dir == :asc -> :desc
        true -> :asc
      end

    page_href(path, %{filters | sort: sort, dir: dir}, 1)
  end

  defp task_href(board_path, doc_id), do: board_path <> "?" <> URI.encode_query(task: doc_id)

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(%{loading: true} = assigns) do
    ~H"""
    <main class="bp-page tl-page" data-test-id="task-list-loading">
      <p class="tl-note">Loading tasks…</p>
    </main>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, :filtered?, ListQuery.filtered?(assigns.filters))

    ~H"""
    <ListStyles.styles />
    <main class="bp-page tl-page" data-role="task-list">
      <div class="bp-head">
        <div>
          <h1 class="bp-h1">Tasks</h1>
          <p class="bp-sub">
            Every task, closed and cancelled included. Open a row to see the task on the board.
          </p>
        </div>
        <.link navigate={@board_path} class="tl-switch" data-role="board-link">Board</.link>
      </div>

      <form class="tl-form" phx-change="filter" phx-submit="filter" data-role="filter-form">
        <input
          type="search"
          name="q"
          value={@filters.q}
          placeholder="Search title or id"
          aria-label="Search tasks by title or id"
          phx-debounce="300"
          class="tl-input tl-input--q"
          data-role="search"
        />
        <input
          :if={@can.worker}
          type="text"
          name="assignee"
          value={@filters.assignee}
          placeholder="Assignee"
          aria-label="Filter by assignee"
          phx-debounce="400"
          class="tl-input"
        />
        <input
          :if={@can.labels}
          type="text"
          name="label"
          value={@filters.label}
          placeholder="Label"
          aria-label="Filter by label"
          phx-debounce="400"
          class="tl-input"
        />
        <input
          :if={@can.parent}
          type="text"
          name="parent"
          value={if is_binary(@filters.parent), do: @filters.parent, else: ""}
          placeholder="Goal id"
          aria-label="Show tasks under this goal id"
          phx-debounce="400"
          class="tl-input"
        />
      </form>

      <div class="tl-chips" data-role="filters">
        <button
          :for={status <- ListQuery.statuses()}
          type="button"
          class={["bp-chip", status in @filters.statuses && "is-active"]}
          aria-pressed={to_string(status in @filters.statuses)}
          phx-click="toggle-status"
          value={status}
          data-role="status-chip"
          data-status={status}
        >
          <%= status_label(status) %>
        </button>
        <span :if={@can.priority} class="tl-sep" aria-hidden="true"></span>
        <button
          :for={p <- if(@can.priority, do: ListQuery.priorities(), else: [])}
          type="button"
          class={["bp-chip", p in @filters.priorities && "is-active"]}
          aria-pressed={to_string(p in @filters.priorities)}
          phx-click="toggle-priority"
          value={p}
          data-role="priority-chip"
        >
          P<%= p %>
        </button>
        <span :if={@can.parent} class="tl-sep" aria-hidden="true"></span>
        <button
          :if={@can.parent}
          type="button"
          class={["bp-chip", @filters.parent == :none && "is-active"]}
          aria-pressed={to_string(@filters.parent == :none)}
          phx-click="toggle-no-parent"
          data-role="no-parent-chip"
        >
          No parent
        </button>
        <button
          :if={@filtered?}
          type="button"
          class="bp-chip tl-clear"
          phx-click="clear-filters"
          data-role="clear-filters"
        >
          Clear filters
        </button>
        <span class="tl-count" data-role="match-count" data-total={@result.total}>
          <%= count_text(@result.total, @filtered?) %>
        </span>
      </div>

      <p :if={@result.total == 0 and not @filtered?} class="tl-note" data-role="list-empty">
        No tasks yet. Create one with <code>bp task create</code> and it shows up here.
      </p>
      <p :if={@result.total == 0 and @filtered?} class="tl-note" data-role="list-no-match">
        No tasks match. Change the search or clear the filters.
      </p>

      <table :if={@result.total > 0} class="tl-table" data-role="task-table">
        <thead>
          <tr>
            <th><.sort_head label="Title" sort="title" path={@path} filters={@filters} /></th>
            <th>Status</th>
            <th>
              <.sort_head
                :if={@can.priority}
                label="Priority"
                sort="priority"
                path={@path}
                filters={@filters}
              />
            </th>
            <th>Assignee</th>
            <th>Goal</th>
            <th>Labels</th>
            <th>Criteria</th>
            <th><.sort_head label="Updated" sort="updated" path={@path} filters={@filters} /></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @result.rows} data-role="task-row" data-doc-id={row.doc_id}>
            <td class="tl-title">
              <.link navigate={task_href(@board_path, row.doc_id)} data-role="task-link">
                <%= row.title || row.doc_id %>
              </.link>
              <span class="tl-id"><%= row.doc_id %></span>
            </td>
            <td class="tl-nowrap" data-role="status" data-status={row.status}>
              <span class={"gi gi--#{status_role(row.status)}"} aria-hidden="true"><%= glyph(row.status) %></span>
              <%= status_label(row.status) %>
            </td>
            <td>
              <span :if={row.priority != nil} class="bp-pip" data-priority={row.priority}>
                P<%= row.priority %>
              </span>
            </td>
            <td>
              <.link
                :if={row.worker}
                patch={href(@path, @filters, %{"assignee" => row.worker})}
                class="tl-quiet"
                data-role="row-assignee"
              ><%= row.worker %></.link>
            </td>
            <td>
              <.link
                :if={row.parent_id}
                patch={href(@path, @filters, %{"parent" => row.parent_id})}
                class="bp-goal"
                title={"Show tasks under " <> row.parent_id}
                data-role="row-goal"
              ><%= row.parent_title || row.parent_id %></.link>
            </td>
            <td>
              <.link
                :for={label <- row.labels}
                patch={href(@path, @filters, %{"label" => label})}
                class="bp-label"
                data-role="row-label"
              ><%= label %></.link>
              <span :if={row.more_labels > 0} class="bp-label">+<%= row.more_labels %></span>
            </td>
            <td class="tl-nowrap tl-num" data-role="criteria">
              <%= if row.criteria, do: "#{row.criteria.met}/#{row.criteria.total}" %>
            </td>
            <td class="tl-nowrap tl-num">
              <time :if={row.updated_at} datetime={iso(row.updated_at)} title={iso(row.updated_at)}>
                <%= age(row.updated_at) %>
              </time>
            </td>
          </tr>
        </tbody>
      </table>

      <nav :if={@result.pages > 1} class="tl-pager" data-role="pager" aria-label="Pages">
        <.link
          :if={@result.page > 1}
          patch={page_href(@path, @filters, @result.page - 1)}
          class="bp-chip"
          data-role="page-prev"
        >Previous</.link>
        <span data-role="page-now">Page <%= @result.page %> of <%= @result.pages %></span>
        <.link
          :if={@result.page < @result.pages}
          patch={page_href(@path, @filters, @result.page + 1)}
          class="bp-chip"
          data-role="page-next"
        >Next</.link>
      </nav>
    </main>
    """
  end

  attr :label, :string, required: true
  attr :sort, :string, required: true
  attr :path, :string, required: true
  attr :filters, :map, required: true

  defp sort_head(assigns) do
    ~H"""
    <.link
      patch={sort_href(@path, @filters, @sort)}
      class={["tl-sort", @filters.sort == @sort && "is-active"]}
      data-role="sort"
      data-sort={@sort}
      aria-label={"Sort by " <> String.downcase(@label)}
    >
      <%= @label %><span :if={@filters.sort == @sort} aria-hidden="true"><%= if @filters.dir == :asc, do: " ↑", else: " ↓" %></span>
    </.link>
    """
  end

  # ── small presentation helpers ──────────────────────────────────────────────

  defp count_text(1, true), do: "1 task matches"
  defp count_text(n, true), do: "#{delimit(n)} tasks match"
  defp count_text(1, false), do: "1 task"
  defp count_text(n, false), do: "#{delimit(n)} tasks"

  defp delimit(n) do
    n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+$)/, ",")
  end

  defp status_label(status) when is_binary(status),
    do: status |> String.replace("_", " ") |> String.capitalize()

  # A status this build does not know paints the neutral mark, as on the board.
  defp status_role(status), do: if(status in ListQuery.statuses(), do: status, else: "unknown")

  defp glyph(status) do
    glyphs = Board.glyphs()
    Enum.find_value(glyphs, glyphs[:unknown], fn {k, v} -> Atom.to_string(k) == status && v end)
  end

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"

  defp age(%NaiveDateTime{} = dt), do: age(DateTime.from_naive!(dt, "Etc/UTC"))

  defp age(%DateTime{} = dt) do
    case max(DateTime.diff(DateTime.utc_now(), dt, :second), 0) do
      s when s < 60 -> "now"
      s when s < 3_600 -> "#{div(s, 60)}m"
      s when s < 86_400 -> "#{div(s, 3_600)}h"
      s when s < 604_800 -> "#{div(s, 86_400)}d"
      _ -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end
end
