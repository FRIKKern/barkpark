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
      read at all.
  """

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

  @doc "The epic-goal line for a workflow session; nil when unavailable."
  @spec epic_goal(t(), String.t() | nil, String.t()) :: map() | nil
  def epic_goal(nil, _provider, _session_id), do: nil

  def epic_goal(reader, provider, session_id) when is_atom(reader),
    do: StudioChat.epic_goal(provider, session_id)
end
