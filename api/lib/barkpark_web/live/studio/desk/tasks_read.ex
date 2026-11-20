defmodule BarkparkWeb.Studio.Desk.TasksRead do
  @moduledoc """
  The reads behind the desk's Tasks sidebar (`Desk.TasksPanel`): whether the
  sidebar is offered at all, the two lists, and one task.

  ## When it is offered

  Only on a desk with a workspace, and only while the Tasks plugin is on for
  that workspace. The plugin check is `PaperTaskSeam.resolver/1`, the same
  answer the Studio's paper editor and chat use, so the desk cannot disagree
  with them. The desk itself is for workspace admins only (`DeskLive`), so the
  sidebar is too.

  ## What it reads

  The rows the plugin's own Tasks list reads (`ListQuery.page/2`): task
  documents in the desk's dataset, held to the desk's workspace, draft twins
  collapsed. Every read needs a workspace id; there is no read across
  workspaces. Fields go through the board's fail-closed predicate
  (`Board.field_visibility_gate/1`), so a field the task schema keeps private
  is left out here as it is on the board.

  The views, against TanStack's (`TasksPanel.tsx`):

    * All: every task, To Do and Done. Barkpark's analogue of a plain list.
    * Active Document: the tasks that link to the document open in the desk,
      through their linked papers, their design paper, or their parent.

  TanStack's Assigned and Subscribed are left out. A Barkpark task's assignee
  is a worker id, not a desk user, and a task has no subscriber list.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Content.DraftId
  alias Barkpark.Plugins.Tasks.Web.ListQuery
  alias Barkpark.Repo
  alias Barkpark.Tasks
  alias Barkpark.Tasks.Board
  alias Barkpark.Tasks.Query
  alias BarkparkWeb.Studio.StudioLive.PaperTaskSeam

  # To Do is every status but these two (TanStack's: every state but done).
  @done ~w(done)
  @hidden ~w(cancelled)

  @doc "True when the desk offers the Tasks sidebar for `workspace`."
  @spec available?(term()) :: boolean()
  def available?(%{id: ws_id}) when is_binary(ws_id), do: PaperTaskSeam.resolver(ws_id) != nil
  def available?(_), do: false

  @doc """
  One list: `%{todo: rows, done: rows, more: n}`, each group the newest
  first and one page long (`ListQuery.page_size/0`); `more` counts the To Do
  rows past that page. `tab` is `"all"` or `"document"`; the document tab
  with no `:target` is empty.

  `opts`: `:dataset` and `:workspace_id` (both required), `:target`.
  """
  @spec list(String.t(), keyword()) :: %{todo: [map()], done: [map()], more: non_neg_integer()}
  def list("document", opts) do
    case Keyword.get(opts, :target) do
      id when is_binary(id) -> read_list(opts, id)
      _ -> %{todo: [], done: [], more: 0}
    end
  end

  def list(_all, opts), do: read_list(opts, nil)

  defp read_list(opts, target) do
    dataset = Keyword.fetch!(opts, :dataset)
    ws_id = workspace!(opts)
    readable? = Board.field_visibility_gate(dataset)
    page_opts = [dataset: dataset, workspace_id: ws_id, readable?: readable?]
    todo = ListQuery.page(filters(ListQuery.statuses() -- (@done ++ @hidden), target), page_opts)
    done = ListQuery.page(filters(@done, target), page_opts)

    %{todo: todo.rows, done: done.rows, more: max(0, todo.total - length(todo.rows))}
  end

  defp filters(statuses, target) do
    %{
      q: "",
      statuses: statuses,
      priorities: [],
      assignee: "",
      label: "",
      parent: nil,
      target: target,
      sort: "updated",
      dir: :desc,
      page: 1
    }
  end

  @doc """
  One task by its id, or nil when the workspace has no such task in the
  dataset. The fields the sidebar's task view shows, each gated as on the
  board.

  `opts`: `:dataset` and `:workspace_id` (both required).
  """
  @spec get(term(), keyword()) :: map() | nil
  def get(id, opts) when is_binary(id) and id != "" do
    dataset = Keyword.fetch!(opts, :dataset)
    ws_id = workspace!(opts)
    published = DraftId.published_id(id)

    from(d in Document,
      where:
        d.type == "task" and d.dataset == ^dataset and d.workspace_id == ^ws_id and
          d.doc_id in ^[published, "drafts." <> published]
    )
    |> Query.collapse_twins()
    |> Repo.all()
    |> Enum.sort_by(&DraftId.draft?(&1.doc_id))
    |> List.first()
    |> case do
      nil -> nil
      doc -> view(doc, Board.field_visibility_gate(dataset))
    end
  end

  def get(_id, _opts), do: nil

  defp view(%Document{} = doc, readable?) do
    content = doc.content || %{}
    shown = fn field -> if readable?.(field), do: present(Map.get(content, field)) end

    %{
      doc_id: DraftId.published_id(doc.doc_id),
      title: doc.title,
      status: Map.get(content, "lifecycle_status") || "open",
      description: shown.("description"),
      priority: if(readable?.("priority"), do: Map.get(content, "priority")),
      due_at: shown.("due_at"),
      worker:
        if(readable?.("assignee") and readable?.("claim"),
          do: present(Map.get(content, "assignee") || get_in(content, ["claim", "worker"]))
        ),
      parent_id: shown.("parent_id"),
      criteria: Tasks.criteria_progress(content)
    }
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(value) when is_integer(value), do: value
  defp present(_), do: nil

  # A read without a workspace would read every workspace (`ListQuery`'s nil).
  defp workspace!(opts) do
    case Keyword.fetch!(opts, :workspace_id) do
      ws_id when is_binary(ws_id) and ws_id != "" ->
        ws_id

      other ->
        raise ArgumentError, "a desk task read needs a workspace id, got: #{inspect(other)}"
    end
  end
end
