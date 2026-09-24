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
  Follow-up: switch this read to `Barkpark.Content.PluginLoadOrder` once
  PR #20148 lands (it unifies the load-order read the holders copy).

  `nil` — nothing published (the `BARKPARK_PLUGINS=""` kill switch registers
  nothing; Registry init publishes `[]`) or no plugin in the load order
  declares a resolver — is the "unavailable" answer: papers render an explicit
  placeholder for the chip criteria segment and every task query block, never
  an empty list that reads as "no tasks".
  """

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

  @doc "The resolver module to read task data through, or `nil` (unavailable)."
  @spec get() :: module() | nil
  def get do
    declared = :persistent_term.get(@key, [])

    case Application.get_env(:barkpark, :plugins, []) do
      [_ | _] = configured -> Enum.find_value(configured, &resolver_for(declared, &1))
      _ -> Enum.find_value(declared, & &1.resolver)
    end
  end

  defp resolver_for(declared, name) when is_binary(name), do: by(declared, :name, name)
  defp resolver_for(declared, {name, _mod}) when is_binary(name), do: by(declared, :name, name)
  defp resolver_for(declared, mod) when is_atom(mod), do: by(declared, :module, mod)
  defp resolver_for(_declared, _other), do: nil

  defp by(declared, field, value) do
    case Enum.find(declared, &(Map.fetch!(&1, field) == value)) do
      nil -> nil
      entry -> entry.resolver
    end
  end
end
