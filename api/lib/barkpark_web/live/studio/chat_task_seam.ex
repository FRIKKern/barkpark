defmodule BarkparkWeb.Studio.ChatTaskSeam do
  @moduledoc """
  The ONE place the Studio chat LiveView reads the task ledger
  (task-ed873c9ae56685b7): the Doing strip's held claims, the ready picker,
  the epic siblings the strip joins agent labels against, the sidebar's
  epic-goal line, and the criteria meter on an epic row.

  ## The gate

  Availability is `PaperTaskSeam.resolver/1` — the SAME answer the Studio
  paper editor uses, so the two Studio surfaces cannot disagree about whether
  tasks exist in a workspace. It reads `Barkpark.Content.PaperTaskResolver`
  (the content-owned holder the Registry publishes every plugin's
  `paper_task_resolver/0` declaration into), finds the registered plugin that
  declared it (`Registry.all/0` + `function_exported?/3`), and checks that
  plugin is enabled for the workspace (`Barkpark.Plugins.Enablement`). `nil`
  means "tasks unavailable here": every read below answers empty, and ChatLive
  renders no Doing strip, no ready picker and no picker toggle.

  Resolve ONCE per mount or session open (`resolve/1`) and hand the result to
  the reads: `Enablement.effective/1` is a Repo read, and the document-stream
  fold calls `criteria_progress/2` per task frame.

  ## What goes through the plugin contract, and what does not

    * `criteria_progress/2` is a `Barkpark.Content.PaperTaskResolver`
      callback, so it is dispatched to the resolved module — the plugin
      contract, not a module name.
    * `ready/2` and `held_claims/3` have NO callback on that contract (it
      carries `criteria_progress/1`, `rows_for_query/3`, `agg_for_query/3`;
      `rows_for_query/3` cannot express the dependency-gated ready queue).
      They are guarded reaches into `Barkpark.Tasks`, which the tasks
      plugin's own manifest (`priv/plugins/tasks/plugin.json`) describes as
      core machinery that "stays in core as reusable utilities". This module
      is the only chat file that names it. Moving them behind the plugin
      contract needs two callbacks on `PaperTaskResolver` and their
      delegations in `Barkpark.Tasks.PaperResolver` — api-owned files.
    * `epic_children/3` and `epic_goal/3` are `Barkpark.StudioChat` reads of
      task documents; they are gated here so ChatLive has no ungated task
      read at all. Both span the workspace's datasets, so a dataset-bound
      token's rows are narrowed here (`only_bound/2`, `epic_goal/3`).
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.Tasks
  alias BarkparkWeb.Studio.StudioLive.PaperTaskSeam

  @typedoc "A resolved task reader: the paper task resolver module, or nil (unavailable)."
  @type t :: module() | nil

  @doc """
  The task reader for `workspace_id`, or nil when tasks are unavailable there.

  A `nil` workspace (the flat instance-admin mount, or a viewer authorized
  nowhere) resolves against the plugins' DECLARATION defaults, the same
  `Enablement.effective(nil)` answer every other workspace-less surface gets.
  That keeps the flat admin's global epic-goal fold; the workspace-keyed reads
  stay fail-closed on their own (ChatLive short-circuits a nil workspace).
  """
  @spec resolve(binary() | nil) :: t()
  def resolve(workspace_id) when is_binary(workspace_id) or is_nil(workspace_id),
    do: PaperTaskSeam.resolver(workspace_id)

  @doc "Whether a resolved reader can serve task reads."
  @spec available?(t()) :: boolean()
  def available?(reader), do: is_atom(reader) and not is_nil(reader)

  @doc "The ready-queue head under `opts` (`Tasks.ready/1` options); `[]` when unavailable."
  @spec ready(t(), keyword()) :: [map()]
  def ready(nil, _opts), do: []
  def ready(reader, opts) when is_atom(reader), do: Tasks.ready(opts)

  @doc "The in_progress rows `worker` holds under `scope`, newest first; `[]` when unavailable."
  @spec held_claims(t(), String.t() | nil, keyword()) :: [map()]
  def held_claims(nil, _worker, _scope), do: []

  def held_claims(reader, worker, scope) when is_atom(reader) do
    [worker: worker, limit: 10]
    |> Kernel.++(scope)
    |> Tasks.prime()
    |> Map.get(:in_progress, [])
  end

  @doc """
  The extra read scope for a dataset-bound token: its own dataset. `[]` for
  everyone else, who names none and spans the scope's datasets as before.
  """
  @spec bound_scope(term()) :: keyword()
  def bound_scope(principal) do
    case Barkpark.Auth.ApiToken.bound_dataset(principal) do
      nil -> []
      dataset -> [dataset: dataset]
    end
  end

  @doc "Keep only the rows of a dataset-bound token's dataset (`Tasks.prime/1` takes no dataset)."
  @spec only_bound([map()], term()) :: [map()]
  def only_bound(docs, principal) do
    case bound_scope(principal) do
      [] -> docs
      [dataset: dataset] -> Enum.filter(docs, &(&1.dataset == dataset))
    end
  end

  @doc """
  True when `dataset` is one a dataset-bound token may read: its own. Always
  true for everyone else. The Doing strip's live frames ride the LEDGER
  dataset's stream and carry no dataset of their own, so the strip asks before
  it subscribes: a token bound elsewhere takes no ledger subscription.
  """
  @spec in_binding?(String.t(), term()) :: boolean()
  def in_binding?(dataset, principal), do: bound_scope(principal) in [[], [dataset: dataset]]

  @doc "A task row's `%{met, total}` criteria count through the plugin contract; nil when unavailable."
  @spec criteria_progress(t(), map() | nil) :: map() | nil
  def criteria_progress(nil, _content), do: nil

  def criteria_progress(reader, content) when is_atom(reader),
    do: reader.criteria_progress(content)

  @doc "Every published task under `parent_ids` in `workspace_id`; `[]` when unavailable."
  @spec epic_children(t(), [String.t()], binary() | nil) :: [map()]
  def epic_children(nil, _parent_ids, _workspace_id), do: []

  def epic_children(reader, parent_ids, workspace_id) when is_atom(reader),
    do: StudioChat.epic_children(parent_ids, workspace_id)

  @doc """
  The epic-goal line for a workflow session row; nil when unavailable. A
  dataset-bound token gets the line only when the epic is a task of its own
  dataset, with the slice count taken over that dataset's children.
  """
  @spec epic_goal(t(), %{provider: String.t() | nil, id: String.t()}, term()) :: map() | nil
  def epic_goal(nil, _session, _principal), do: nil

  def epic_goal(reader, %{provider: provider, id: session_id}, principal) when is_atom(reader) do
    provider |> StudioChat.epic_goal(session_id) |> bound_epic_goal(principal)
  end

  @doc """
  Hold a `StudioChat.epic_goal/2` answer to a dataset-bound token's dataset;
  everyone else gets it back unchanged. The chat session JSON asks this too, so
  the wire and the sidebar agree.
  """
  @spec bound_epic_goal(map() | nil, term()) :: map() | nil
  def bound_epic_goal(goal, principal) do
    case bound_scope(principal) do
      [dataset: dataset] when is_map(goal) -> bound_epic_goal(goal, dataset, principal)
      _ -> goal
    end
  end

  # `StudioChat.epic_goal/2` reads by workspace and names no dataset, so its
  # answer is only the epic's id here: the row and its children are read again
  # inside the token's dataset. The count is capped: `epic_children/2` stops at
  # 500 rows across the workspace's datasets.
  defp bound_epic_goal(%{id: id}, dataset, %{workspace_id: ws}) when is_binary(ws) do
    epic =
      Repo.one(
        from d in Document,
          where: d.type == "task" and d.doc_id == ^id,
          where: d.dataset == ^dataset and d.workspace_id == ^ws,
          limit: 1
      )

    if epic do
      slices = Enum.filter(StudioChat.epic_children([id], ws), &(&1.dataset == dataset))
      done = Enum.count(slices, &((&1.content || %{})["lifecycle_status"] in ~w(done cancelled)))
      content = epic.content || %{}

      %{
        id: id,
        title: epic.title || content["title"] || id,
        slices_done: done,
        slices_total: length(slices),
        wave_status:
          if(content["wave_status"] in [nil, ""], do: nil, else: content["wave_status"])
      }
    end
  end

  defp bound_epic_goal(_goal, _dataset, _principal), do: nil
end
