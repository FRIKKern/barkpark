defmodule Barkpark.Validation.Registry do
  @moduledoc """
  Registry of value-checkers consumed by the `{:matches, name}` op.

  Backed by an ETS table for read-fast `find/1` from the hot evaluator
  path. Writes flow through this GenServer so insertion is serialised
  and ownership is clean across hot reloads.

  ## Built-ins

      "isbn13"   → Barkpark.Validation.Checkers.Isbn13Checksum
      "gtin14"   → Barkpark.Validation.Checkers.Gtin14Checksum
      "iso639"   → Barkpark.Validation.Checkers.Iso639Language
      "iso4217"  → Barkpark.Validation.Checkers.Iso4217Currency
      "nonempty" → Barkpark.Validation.Checkers.Nonempty

  ## Plugin checkers

  Plugins return `[{checker_name :: String.t(), module}]` from the
  optional `Barkpark.Plugin` `checkers/0` callback (Phase 2 contract).
  Registration is namespaced as `plugin:<plugin_name>:<checker_name>` so
  built-in names can never collide with plugin-supplied checkers.

  Call `reload_plugin_checkers/0` after `Barkpark.Plugins.Registry`
  finishes its boot-time discovery pass — `Barkpark.Application` does
  this automatically. Tests can call `register/2` directly.
  """

  use GenServer
  require Logger

  alias Barkpark.Validation.Checker

  @name __MODULE__
  @table :barkpark_validation_checkers

  @builtins %{
    "isbn13" => Barkpark.Validation.Checkers.Isbn13Checksum,
    "gtin14" => Barkpark.Validation.Checkers.Gtin14Checksum,
    "iso639" => Barkpark.Validation.Checkers.Iso639Language,
    "iso4217" => Barkpark.Validation.Checkers.Iso4217Currency,
    "nonempty" => Barkpark.Validation.Checkers.Nonempty
  }

  @typedoc "Checker name used for registration and lookup."
  @type checker_name :: String.t()

  # ── Public API ──────────────────────────────────────────────────────────

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

  @spec find(String.t()) :: {:ok, module()} | :error
  def find(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, mod}] -> {:ok, mod}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Alias for `find/1`. WI3 entry point used by plugin loaders and tests.
  """
  @spec lookup(checker_name()) :: {:ok, module()} | :error
  def lookup(name) when is_binary(name), do: find(name)

  @spec register(String.t(), module()) :: :ok
  def register(name, module) when is_binary(name) and is_atom(module) do
    GenServer.call(@name, {:register, name, module})
  end

  @spec all() :: [%{name: String.t(), module: module()}]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {n, m} -> %{name: n, module: m} end)
  rescue
    ArgumentError -> []
  end

  @doc """
  Iterate `Barkpark.Plugins.Registry.all/0` and register every plugin's
  `checkers/0` slot under the `plugin:<name>:<checker>` namespace.
  Idempotent. Safe to call multiple times.
  """
  @spec reload_plugin_checkers() :: :ok
  def reload_plugin_checkers do
    GenServer.call(@name, :reload_plugin_checkers, 30_000)
  end

  @doc """
  Built-in checker names (`MapSet.t()` of strings).
  """
  @spec builtin_names() :: MapSet.t()
  def builtin_names, do: MapSet.new(Map.keys(@builtins))

  @doc """
  Convenience entry point used by the rule DSL `:matches:<checker>` op.

  Looks up `name`, dispatches to `module.check/2`, and surfaces a stable
  error tuple when the checker is unknown.
  """
  @spec check(checker_name(), term(), Checker.params()) ::
          :ok | {:error, Checker.reason()} | {:error, :unknown_checker}
  def check(name, value, params) when is_binary(name) and is_map(params) do
    case find(name) do
      {:ok, module} -> module.check(value, params)
      :error -> {:error, :unknown_checker}
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])

        existing ->
          existing
      end

    Enum.each(@builtins, fn {name, mod} -> :ets.insert(@table, {name, mod}) end)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, name, module}, _from, state) do
    :ets.insert(@table, {name, module})
    {:reply, :ok, state}
  end

  def handle_call(:reload_plugin_checkers, _from, state) do
    plugins = safe_plugins_list()

    Enum.each(plugins, fn entry ->
      pname = Map.get(entry, :name)
      pmod = Map.get(entry, :module)
      load_one_plugin(pname, pmod)
    end)

    {:reply, :ok, state}
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp load_one_plugin(pname, pmod)
       when is_binary(pname) and is_atom(pmod) and not is_nil(pmod) do
    if Code.ensure_loaded?(pmod) and function_exported?(pmod, :checkers, 0) do
      try do
        for {cname, cmod} <- pmod.checkers(),
            is_binary(cname) or is_atom(cname),
            is_atom(cmod) do
          full = "plugin:" <> pname <> ":" <> to_string(cname)
          :ets.insert(@table, {full, cmod})
        end

        :ok
      rescue
        e ->
          Logger.warning(
            "Barkpark.Validation.Registry: plugin #{pname} checkers/0 raised: #{inspect(e)}"
          )

          :error
      end
    else
      :ok
    end
  end

  defp load_one_plugin(_, _), do: :ok

  defp safe_plugins_list do
    if Process.whereis(Barkpark.Plugins.Registry) do
      Barkpark.Plugins.Registry.all()
    else
      []
    end
  rescue
    _ -> []
  end
end
