defmodule Barkpark.Content.ResolveDocGuards do
  @moduledoc """
  The content-owned holder for plugin guards on the canonical slug resolver,
  `Barkpark.Content.Graph.resolve_doc/3` (`Barkpark.Plugin.resolve_doc_guards/0`,
  task-c10be8a9ad8f0145).

  Built like `Barkpark.Content.MutateDoorFences`, for the same reason: the
  dependency points into content, never out of it. `Content.Graph` must not
  name a plugin, so the Registry PUBLISHES each registered plugin's declared
  guards here (`publish/1`, on every register / reset and at Registry init) and
  the resolver only ever calls `run!/3`. Nothing published (the
  `BARKPARK_PLUGINS=""` kill switch registers nothing; Registry init publishes
  `[]`) resolves `[]`, and `run!/3` is `:ok`.

  The one guard today is the Tasks plugin's twin rule: a `type: "task"` id whose
  winning rows span more than one dataset in scope, asked for with no dataset
  named, RAISES a 409 `ambiguous_dataset` refusal instead of letting the
  resolver pick a dataset the caller never named.

  Every guard is called as `apply(module, function, [rows, doc_id, dataset])`:
  `rows` are every row the resolver's scoped query returned (published
  spelling first), `doc_id` the published id, `dataset` the dataset the caller
  named (or `nil`). A guard returns `:ok` or RAISES; the raise is the refusal.
  A guard raises rather than returning an error because every caller of
  `resolve_doc/3` collapses `nil` into "not found", which would turn a refusal
  into a silent empty answer. The raised exception renders through
  `Barkpark.Content.ErrorEnvelope`.

  NOT filtered by per-workspace enablement, the same integrity-gate rule as
  `mutate_door_fences/0`: the guard protects which ROW a read answers with, so
  switching the plugin off for one workspace must not change it.

  LOAD ORDER. `list/0` applies the `:barkpark, :plugins` load order at READ
  time through `Barkpark.Content.PluginLoadOrder.plugins/3`, like the fence
  holders.
  """

  @key {__MODULE__, :declared}

  @typedoc "One guard: `{module, function}`, called with `[rows, doc_id, dataset]`."
  @type guard :: {module(), atom()}

  @typedoc "One registered plugin's declaration."
  @type declared :: %{name: String.t(), module: module(), guards: [guard()]}

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

  @doc "The guards to run, in plugin load order (each plugin's own order kept)."
  @spec list() :: [guard()]
  def list do
    declared = :persistent_term.get(@key, [])

    case Application.get_env(:barkpark, :plugins, []) do
      [_ | _] = configured ->
        configured
        |> Barkpark.Content.PluginLoadOrder.plugins(declared, __MODULE__)
        |> Enum.flat_map(& &1.guards)

      _ ->
        Enum.flat_map(declared, & &1.guards)
    end
  end

  @doc """
  Run every published guard on one resolution. Returns `:ok`; a guard's raise
  propagates unchanged.
  """
  @spec run!([struct()], String.t(), String.t() | nil) :: :ok
  def run!(rows, doc_id, dataset) do
    Enum.each(list(), fn {mod, fun} -> apply(mod, fun, [rows, doc_id, dataset]) end)
  end
end
