defmodule BarkparkWeb.Studio.Desk.TasksPanel do
  @moduledoc """
  The desk's Tasks sidebar, as the TanStack Studio's (`TasksPanel.tsx`, J66):
  the navbar's Tasks button opens it at the right under the navbar, and the
  phone drawer has the same button. Under 900 px it lies over the panes;
  under 600 px it takes the whole width.

  It opens on a list with two tabs (`Desk.TasksRead` says what each reads):

    * All: To Do open, Done folded, each the newest first.
    * Active Document: the tasks that link to the document open in the desk.

  A task's title opens its view: its status, description, deadline, worker,
  priority, criteria, and a link that opens the task in the desk to edit it.
  The view reads only. "Tasks" goes back to the list, and the previous and
  next buttons walk the list it was opened from.

  The focus never falls to the page: a task's view puts it on "Tasks", and
  going back puts it on the task's title in the list, unfolding Done when the
  task is done (or on the tab, when the task is not listed there). The previous and next buttons stay focusable at
  the ends (`aria-disabled`), so the focus stays on them.

  The open state is `DeskLive`'s (`:desk_tasks_open?`), so the navbar's
  button shows `aria-pressed`; the list and the view are this component's.
  """
  use Phoenix.LiveComponent
  use Gettext, backend: BarkparkWeb.Gettext

  alias BarkparkWeb.Studio.Desk.Search
  alias BarkparkWeb.Studio.Desk.TasksRead
  alias Phoenix.LiveView.JS

  @doc "The navbar's Tasks button. Under 900 px it gives way to the drawer's."
  attr :open, :boolean, default: false

  def button(assigns) do
    ~H"""
    <button
      id="dk-tasks-btn"
      type="button"
      class="icon-btn tasks-btn"
      aria-label={gettext("Tasks")}
      data-tip={gettext("Tasks")}
      aria-pressed={to_string(@open)}
      aria-controls="dk-tasks"
      phx-click="desk-tasks-toggle"
    >
      <BarkparkWeb.Icons.desk_icon name="checkmark-circle" size={21} />
    </button>
    """
  end

  @doc "The drawer's Tasks button: it closes the drawer and toggles the sidebar."
  def drawer_item(assigns) do
    ~H"""
    <button
      type="button"
      class="drawer-item drawer-tasks"
      aria-pressed="false"
      phx-click="desk-tasks-toggle"
      data-desk-drawer-pick
      data-desk-drawer-tasks
    >
      <span class="menu-icon-text">
        <BarkparkWeb.Icons.desk_icon name="checkmark-circle" size={21} />{gettext("Tasks")}
      </span>
    </button>
    """
  end

  @impl true
  def mount(socket) do
    {:ok, assign(socket, tab: "all", task: nil, walk: [], back_to: nil, lists: %{})}
  end

  @impl true
  def update(assigns, socket) do
    target_moved? = Map.get(socket.assigns, :target, :unset) != assigns[:target]

    socket =
      assign(socket, Map.take(assigns, [:id, :dataset, :workspace_id, :target, :base, :root]))

    socket =
      cond do
        socket.assigns.lists == %{} -> load(socket)
        target_moved? and socket.assigns.tab == "document" -> load(socket)
        true -> socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ["all", "document"] do
    {:noreply, socket |> assign(tab: tab, task: nil, back_to: nil) |> load()}
  end

  def handle_event("open", %{"id" => id}, socket) when is_binary(id) do
    %{todo: todo, done: done} = socket.assigns.lists
    walk = Enum.map(todo ++ done, & &1.doc_id)
    {:noreply, show(socket, id, walk)}
  end

  def handle_event("walk", %{"to" => dir}, socket) when dir in ["prev", "next"] do
    %{walk: walk, task: task} = socket.assigns
    at = task && Enum.find_index(walk, &(&1 == task.doc_id))
    to = at && if(dir == "prev", do: at - 1, else: at + 1)

    if to && to >= 0 && to < length(walk),
      do: {:noreply, show(socket, Enum.at(walk, to), walk)},
      else: {:noreply, socket}
  end

  def handle_event("back", _params, socket) do
    back_to = if socket.assigns.task, do: socket.assigns.task.doc_id, else: :tab
    {:noreply, socket |> assign(task: nil, back_to: back_to) |> load()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp show(socket, id, walk) do
    case TasksRead.get(id, read_opts(socket)) do
      nil -> socket
      task -> assign(socket, task: task, walk: walk)
    end
  end

  defp load(socket) do
    lists = TasksRead.list(socket.assigns.tab, read_opts(socket))
    listed? = Enum.any?(lists.todo ++ lists.done, &(&1.doc_id == socket.assigns.back_to))

    back_to =
      if socket.assigns.back_to in [nil, :tab] or listed?, do: socket.assigns.back_to, else: :tab

    assign(socket, lists: lists, back_to: back_to)
  end

  defp read_opts(socket) do
    [
      dataset: socket.assigns.dataset,
      workspace_id: socket.assigns.workspace_id,
      target: socket.assigns.target
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside id={@id} class="tasks-panel" aria-label={gettext("Tasks")}>
      <%= if @task do %>
        <.task_view task={@task} walk={@walk} base={@base} root={@root} myself={@myself} />
      <% else %>
        <.task_list tab={@tab} lists={@lists} target={@target} back_to={@back_to} myself={@myself} />
      <% end %>
    </aside>
    """
  end

  attr :tab, :string, required: true
  attr :lists, :map, required: true
  attr :target, :string, default: nil
  attr :back_to, :any, default: nil
  attr :myself, :any, required: true

  defp task_list(assigns) do
    assigns = assign(assigns, :empty?, assigns.lists.todo == [] and assigns.lists.done == [])

    ~H"""
    <header class="tasks-head"><h2>{gettext("Tasks")}</h2></header>
    <div class="tasks-tabs" role="tablist" aria-label={gettext("Tasks")}>
      <button
        :for={{id, label} <- tabs()}
        id={"dk-tasks-tab-" <> id}
        type="button"
        role="tab"
        aria-selected={to_string(@tab == id)}
        aria-controls="dk-tasks-body"
        phx-click="tab"
        phx-value-tab={id}
        phx-target={@myself}
        phx-mounted={@tab == id and @back_to == :tab && JS.focus()}
      >{label}</button>
    </div>
    <div id="dk-tasks-body" class="tasks-body" role="tabpanel" aria-labelledby={"dk-tasks-tab-" <> @tab}>
      <div :if={@empty?} class="tasks-empty">
        <h3>{empty(@tab, @target) |> elem(0)}</h3>
        <p>{empty(@tab, @target) |> elem(1)}</p>
      </div>
      <%= if !@empty? do %>
        <%!-- Open or folded is the reader's once drawn: a patch keeps it. --%>
        <details
          :if={@lists.todo != []}
          class="tasks-group"
          open
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>{gettext("To Do")}<BarkparkWeb.Icons.desk_icon name="chevron-down" size={21} /></summary>
          <ul class="tasks-list" aria-label={gettext("To Do")}>
            <.row :for={task <- @lists.todo} task={task} back_to={@back_to} myself={@myself} />
          </ul>
          <p :if={@lists.more > 0} class="tasks-more">
            {ngettext("1 more task to do is not shown", "%{count} more tasks to do are not shown", @lists.more)}
          </p>
        </details>
        <%!-- Folded, unless the task the view came back from is in it. --%>
        <details
          class="tasks-group tasks-done"
          open={Enum.any?(@lists.done, &(&1.doc_id == @back_to))}
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>{gettext("Done")}<BarkparkWeb.Icons.desk_icon name="chevron-down" size={21} /></summary>
          <ul class="tasks-list" aria-label={gettext("Done")}>
            <.row :for={task <- @lists.done} task={task} back_to={@back_to} myself={@myself} />
          </ul>
        </details>
      <% end %>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :back_to, :any, default: nil
  attr :myself, :any, required: true

  defp row(assigns) do
    ~H"""
    <li class="task-row" data-done={@task.status == "done"}>
      <span class="task-state" aria-hidden="true">
        <BarkparkWeb.Icons.desk_icon :if={@task.status == "done"} name="checkmark-circle" size={21} />
        <span :if={@task.status != "done"} class="task-circle"></span>
      </span>
      <div class="task-text">
        <button
          id={"dk-task-" <> @task.doc_id}
          type="button"
          class="task-title"
          phx-click="open"
          phx-value-id={@task.doc_id}
          phx-target={@myself}
          phx-mounted={@back_to == @task.doc_id && JS.focus()}
        >{@task.title || @task.doc_id}</button>
        <span
          :if={@task.status not in ["open", "done"] or @task.parent_title || @task.due_at}
          class="task-meta"
        >
          <span :if={@task.status not in ["open", "done"]}>{status_label(@task.status)}</span>
          <span :if={@task.parent_title} class="task-meta-target">
            <BarkparkWeb.Icons.desk_icon name="document" size={21} />{@task.parent_title}
          </span>
          <span :if={@task.due_at}>{day(@task.due_at)}</span>
        </span>
      </div>
      <span :if={@task.worker} class="task-assignee" title={@task.worker}>
        <span aria-hidden="true">{initials(@task.worker)}</span>
        <span class="sr-only">{gettext("Worker: %{worker}", worker: @task.worker)}</span>
      </span>
    </li>
    """
  end

  attr :task, :map, required: true
  attr :walk, :list, required: true
  attr :base, :string, required: true
  attr :root, :any, required: true
  attr :myself, :any, required: true

  defp task_view(assigns) do
    at = Enum.find_index(assigns.walk, &(&1 == assigns.task.doc_id))

    assigns =
      assign(assigns, first?: at in [nil, 0], last?: is_nil(at) or at >= length(assigns.walk) - 1)

    ~H"""
    <header class="tasks-head">
      <nav class="tasks-crumbs" aria-label={gettext("Tasks")}>
        <button type="button" class="btn-text" phx-click="back" phx-target={@myself} phx-mounted={JS.focus()}>
          {gettext("Tasks")}
        </button>
        <span class="tasks-crumb-sep" aria-hidden="true"><BarkparkWeb.Icons.desk_icon name="chevron-right" size={21} /></span>
        <h2>{@task.title || @task.doc_id}</h2>
      </nav>
      <button
        type="button"
        class="icon-btn"
        aria-label={gettext("Go to previous task")}
        data-tip={gettext("Go to previous task")}
        aria-disabled={to_string(@first?)}
        phx-click="walk"
        phx-value-to="prev"
        phx-target={@myself}
      ><BarkparkWeb.Icons.desk_icon name="chevron-left" size={21} /></button>
      <button
        type="button"
        class="icon-btn"
        aria-label={gettext("Go to next task")}
        data-tip={gettext("Go to next task")}
        aria-disabled={to_string(@last?)}
        phx-click="walk"
        phx-value-to="next"
        phx-target={@myself}
      ><BarkparkWeb.Icons.desk_icon name="chevron-right" size={21} /></button>
    </header>
    <div class="tasks-body task-form">
      <div class="task-view-title" data-done={@task.status == "done"}>
        <span class="task-state" aria-hidden="true">
          <BarkparkWeb.Icons.desk_icon :if={@task.status == "done"} name="checkmark-circle" size={21} />
          <span :if={@task.status != "done"} class="task-circle"></span>
        </span>
        <h3>{@task.title || @task.doc_id}</h3>
      </div>
      <p :if={@task.description} class="task-description">{@task.description}</p>
      <dl class="task-facts">
        <dt>{gettext("Status")}</dt>
        <dd>{status_label(@task.status)}</dd>
        <%= if @task.due_at do %><dt>{gettext("Deadline")}</dt><dd>{day(@task.due_at)}</dd><% end %>
        <%= if @task.worker do %><dt>{gettext("Worker")}</dt><dd>{@task.worker}</dd><% end %>
        <%= if is_integer(@task.priority) do %><dt>{gettext("Priority")}</dt><dd>{@task.priority}</dd><% end %>
        <%= if @task.criteria do %>
          <dt>{gettext("Criteria")}</dt>
          <dd>{gettext("%{met} of %{total} met", met: @task.criteria.met, total: @task.criteria.total)}</dd>
        <% end %>
        <dt>{gettext("Task id")}</dt>
        <dd><code>{@task.doc_id}</code></dd>
      </dl>
      <.link patch={Search.href(@base, @root, %{type: "task", id: @task.doc_id})} class="task-open">
        {gettext("Open the task to edit it")}
      </.link>
    </div>
    """
  end

  defp tabs, do: [{"all", gettext("All")}, {"document", gettext("Active Document")}]

  defp empty("document", nil),
    do:
      {gettext("Open a document to see its task"),
       gettext("Tasks on your active document will be shown here.")}

  defp empty("document", _id),
    do:
      {gettext("This document doesn't have any tasks yet"),
       gettext("Once a document has connected tasks, they will be shown here.")}

  defp empty(_all, _id),
    do: {gettext("No tasks"), gettext("Tasks in this workspace and dataset will be shown here.")}

  @doc "A status as the sidebar names it."
  def status_label("open"), do: pgettext("task status", "Open")
  def status_label("in_progress"), do: gettext("In progress")
  def status_label("blocked"), do: gettext("Blocked")
  def status_label("done"), do: gettext("Done")
  def status_label("cancelled"), do: gettext("Cancelled")
  def status_label("considering"), do: gettext("Considering")
  def status_label("researching"), do: gettext("Researching")
  def status_label(other), do: other

  # The date of a deadline, as the API stores it (ISO 8601): no clock time.
  defp day(<<date::binary-size(10), _::binary>>), do: date
  defp day(other), do: other

  defp initials(worker) do
    worker
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      text -> text
    end
  end
end
