defmodule Barkpark.Content.PaperTaskResolver do
  @moduledoc """
  The content-owned seam through which a paper reads TASK data
  (task-9c59aa555e1e015e, Barkspark phase 1 slice H): a task chip's criteria
  segment and the rows / aggregates of a query-carrying task block.

  THE DEPENDENCY POINTS INTO CONTENT, NEVER OUT OF IT. `Barkpark.Content.Papers`
  must not name `Barkpark.Tasks` (a plugin's substrate) or
  `Barkpark.Plugins.Registry` (kernel→feature). So a plugin declares a resolver
  module through `Barkpark.Plugin.paper_task_resolver/0`, the Registry
  PUBLISHES every registered plugin's declaration here (`publish/1`, on every
  register / reset and at Registry init), and papers only ever read `get/0`.
  The same holder pattern as `Barkpark.Content.PreWriteFences`.

  What is stored is each plugin's declaration; `get/0` applies the
  `:barkpark, :plugins` load order at READ time with the same precedence as
  `PreWriteFences.list/0` (a configured list wins, in its order; otherwise
  alphabetical by plugin name), and the FIRST declared resolver wins.
  Configured entries are interpreted by
  `Barkpark.Content.PluginLoadOrder.plugins/3` (task-21f5264a452b7cf9): an
  entry that published no declaration (a loadable module that never
  registered, an unknown name, a malformed entry) is skipped with a
  `Logger.warning` naming it — never silently.

  PER-WORKSPACE ENABLEMENT (task-857c9f987268a75a). Registration is the
  INSTANCE layer; a workspace can switch a registered plugin off
  (`Barkpark.Plugins.Enablement`, `workspaces.settings["plugins"]`). A paper
  renders task data through `get/1`, keyed by the RENDERED PAPER'S OWN
  workspace (every render site threads `paper.workspace_id` as the task
  scope's `:workspace_id`), and a plugin switched off there declares nothing
  for that paper — the same `nil` answer as "not loaded". `get/0` is the
  instance-wide answer only (which resolver is registered at all); no paper
  render path reads it.

  `nil` — nothing published (the `BARKPARK_PLUGINS=""` kill switch registers
  nothing; Registry init publishes `[]`) or no plugin in the load order
  declares a resolver — is the "unavailable" answer: papers render an explicit
  placeholder for the chip criteria segment and every task query block, never
  an empty list that reads as "no tasks".
  """

  alias Barkpark.Plugins.Enablement

  @key {__MODULE__, :declared}

  @doc """
  A task chip's `%{met, total}` criteria count, or `nil` when the task carries
  none (the chip then omits the segment).
  """
  @callback criteria_progress(content :: map() | nil) ::
              %{met: non_neg_integer(), total: non_neg_integer()} | nil

  @doc "The snapshot rows one task-row query resolves to, under `scope`."
  @callback rows_for_query(query :: map(), scope :: keyword(), opts :: keyword()) :: [map()]

  @doc "The aggregate one data-viz task query resolves to, under `scope`."
  @callback agg_for_query(query :: map(), scope :: keyword(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @typedoc "One registered plugin's declaration."
  @type declared :: %{name: String.t(), module: module(), resolver: module()}

  @doc """
  Replace the published declarations. Called by `Barkpark.Plugins.Registry`
  only. Writes only when the value changes (each `:persistent_term.put/2` is a
  global GC).
  """
  @spec publish([declared()]) :: :ok
  def publish(declared) when is_list(declared) do
    value = Enum.sort_by(declared, & &1.name)

    if :persistent_term.get(@key, :unset) != value do
      :persistent_term.put(@key, value)
    end

    :ok
  end

  @doc """
  The instance-wide resolver (registered + in the load order), or `nil`.
  Ignores per-workspace enablement — a paper render reads `get/1`.
  """
  @spec get() :: module() | nil
  def get, do: Enum.find_value(load_ordered(), & &1.resolver)

  @doc """
  The resolver a paper in `workspace_id` reads task data through, or `nil`
  (unavailable). `workspace_id` is the rendered paper's own workspace. A
  declaring plugin that `Barkpark.Plugins.Enablement` reports switched off for
  that workspace is skipped, so with Tasks off there the paper renders the
  same explicit placeholders as with no resolver loaded. A `nil` workspace
  resolves against the declaration defaults (`Enablement.effective(nil)`).
  """
  @spec get(binary() | nil) :: module() | nil
  def get(workspace_id) do
    case load_ordered() do
      [] ->
        nil

      declared ->
        effective = Enablement.effective(workspace_id)

        Enum.find_value(declared, fn %{name: name, resolver: resolver} ->
          if Enablement.enabled?(effective, name), do: resolver
        end)
    end
  end

  defp load_ordered do
    declared = :persistent_term.get(@key, [])

    case Application.get_env(:barkpark, :plugins, []) do
      [_ | _] = configured ->
        Barkpark.Content.PluginLoadOrder.plugins(configured, declared, __MODULE__)

      _ ->
        declared
    end
    |> Enum.filter(& &1.resolver)
  end
end
