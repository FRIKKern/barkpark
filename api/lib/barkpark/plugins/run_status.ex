defmodule Barkpark.Plugins.RunStatus do
  @moduledoc """
  Tiny in-memory GenServer that records the last bootstrap + last codelist-
  seed run per plugin. Powers the plugin admin LiveView at
  `/studio/:dataset/_plugins`.

  Two kinds of events are tracked:

    * `:bootstrap` — last `Barkpark.Plugins.Bootstrap.install_for_plugin/1`
      result for the named plugin. Carries the result tuple verbatim
      (`{:ok, n}` or `{:error, reason}`).
    * `:seed` — last codelist-seed sweep for the named plugin. Carries
      whatever the per-plugin caller emits (typically `:ok` or
      `{:error, reason}`).
    * `:schemas` — what the last bootstrap of that plugin actually INSTALLED:
      `%{names: [schema_type_name], detail: :installed | :module_not_loaded |
      :no_callback}`. Recorded alongside `:bootstrap` by
      `Barkpark.Plugins.Bootstrap` and read by
      `Barkpark.Plugins.Census.take/1`, which needs the type names — the
      `:bootstrap` result carries only a count, so a plugin that registered
      the WRONG schemas is indistinguishable from one that registered the
      right ones by count alone.

  State is a flat map keyed by plugin name. Records are append-only from
  this process's perspective — every `record/3` overwrites the previous
  entry for that `{plugin_name, kind}` pair.

  Lookups are cheap (a single `GenServer.call`) and the surface is
  intentionally thin: `record/3`, `get/1`, `all/0`. The LV reads `all/0`
  on every render; the bootstrap + seed callers call `record/3`.

  Empty state is the default: a fresh GenServer carries no entries.
  Callers that ask for a plugin with no recorded runs get `%{}` back.
  """

  use GenServer

  @name __MODULE__

  @type kind :: :bootstrap | :seed | :schemas
  @type entry :: %{at: DateTime.t(), result: term()}
  @type plugin_status :: %{optional(kind()) => entry()}

  # ─── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Records a run of the given `kind` for `plugin_name`. The result is
  whatever the caller wants the LV to surface — typically a tagged tuple.
  Returns `:ok`.

  Safe to call even before the GenServer is up (e.g. during early boot in
  tests): the call is wrapped in a defensive try/catch and degrades to a
  no-op if the registered name has not yet been started.
  """
  @spec record(kind(), String.t(), term()) :: :ok
  def record(kind, plugin_name, result)
      when kind in [:bootstrap, :seed, :schemas] and is_binary(plugin_name) do
    # Synchronous call so the LV (and tests) observe the recorded entry
    # immediately after the recording site returns. The state is tiny —
    # a flat per-plugin map — so the call cost is negligible.
    try do
      GenServer.call(@name, {:record, kind, plugin_name, result, DateTime.utc_now()})
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Returns the recorded entries for `plugin_name` as a map keyed by kind.
  Missing plugins return `%{}`.
  """
  @spec get(String.t()) :: plugin_status()
  def get(plugin_name) when is_binary(plugin_name) do
    try do
      GenServer.call(@name, {:get, plugin_name})
    catch
      :exit, _ -> %{}
    end
  end

  @doc """
  Returns the full status map — `%{plugin_name => plugin_status()}`.
  """
  @spec all() :: %{optional(String.t()) => plugin_status()}
  def all do
    try do
      GenServer.call(@name, :all)
    catch
      :exit, _ -> %{}
    end
  end

  @doc """
  Resets every recorded entry. Used by tests; not exposed via the LV.
  """
  @spec reset() :: :ok
  def reset do
    try do
      GenServer.call(@name, :reset)
    catch
      :exit, _ -> :ok
    end
  end

  # ─── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:record, kind, plugin_name, result, at}, _from, state) do
    plugin_entries = Map.get(state, plugin_name, %{})
    updated = Map.put(plugin_entries, kind, %{at: at, result: result})
    {:reply, :ok, Map.put(state, plugin_name, updated)}
  end

  def handle_call({:get, plugin_name}, _from, state) do
    {:reply, Map.get(state, plugin_name, %{}), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{}}
  end
end
