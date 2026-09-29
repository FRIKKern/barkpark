defmodule Barkpark.Content.PluginLoadOrder do
  @moduledoc """
  The ONE interpreter of a `:barkpark, :plugins` load-order entry
  (task-3fbd48182b1d35ea). Every lib reader of the load order hands its
  configured list here instead of pattern-matching entries itself.

  ## Why one interpreter

  Before this module each reader carried its own `module_of` / `name_of` /
  `fences_for` clauses, and they disagreed on one shape: a module that loads
  but is not a registered plugin was RUN by `Plugins.Hooks` and
  `Registry.BootCollectors` and DROPPED — with no log line at `:info` or
  above — by `Registry.ResolverChain`, `Content.PreWriteFences`,
  `Content.PrePublishFences` and `Registry.Discovery`. Unknown plugin-name
  strings, unloadable atoms and malformed entries were dropped silently by
  all of them.

  ## The rule

  Each entry classifies to exactly one of:

    * `{:plugin, known}` — it names a plugin the reader knows (by name for a
      string or a `{name, module}` tuple, by module for an atom or for a
      tuple whose name is unknown);
    * `{:module, module}` — a LOADABLE module that is not a known plugin;
    * `{:drop, entry, reason}` — anything else.

  A `{:module, _}` entry is a MODULE, not a plugin:

    * module-dispatch readers (`modules/3`: `Plugins.Hooks`,
      `Registry.BootCollectors`) RUN it — they only ever call callbacks on a
      module, and `BootCollectors` runs at boot / router compile time before
      the Registry exists, so it could not tell registered from unregistered
      even if it wanted to;
    * plugin-record readers (`plugins/3`: `Registry.ResolverChain`,
      `Content.PreWriteFences`, `Content.PrePublishFences`,
      `Content.PreWriteTransforms`, `Content.PaperTaskResolver`,
      `Content.MutateDoorFences`, `Registry.Discovery`) SKIP it, LOUDLY. What they consume is a product of
      registration — a Registry entry (whose `name` drives enablement and desk
      grouping), a fence declaration the Registry validated and published, or a
      `plugin.json` manifest. Accepting a bare module there would mean
      re-running the Registry's fence validation inside the kernel and
      inventing a plugin name, i.e. letting a non-plugin past the registration
      gate into the integrity-fence chain.

  Test seams rely on the first half: `BumpHook`, `InterleavedWriter`,
  `HaltingPersist` and the `RoutesFake*` / crontab fakes are unregistered
  modules placed in load orders on purpose.

  ## Never silent

  Every entry a reader skips logs `Logger.warning` naming the reader, the
  entry and the reason — once per `{reader, entry}` per VM (a
  `:persistent_term` flag), because the readers sit on hot paths (every write
  fires hooks and fences) and one line per misconfigured entry says it.

  ## Why it lives in `Content`

  `Content` is the kernel, and two readers (`PreWriteFences`,
  `PrePublishFences`) live in it: a `Barkpark.Plugins.*` home would be a
  kernel→feature edge (`tooling/concept-map/ci-boundary.mjs`). The module is
  pure — each reader passes the set of plugins it knows (`known`), so this
  file names no feature.
  """

  require Logger

  @typedoc "A plugin a reader knows: at least its name and module."
  @type known :: %{
          required(:name) => String.t(),
          required(:module) => module(),
          optional(atom()) => term()
        }

  @type reason :: :unknown_name | :unregistered_module | :not_loadable | :bad_shape

  @type resolved :: {:plugin, known()} | {:module, module()} | {:drop, term(), reason()}

  @doc """
  Classify every entry of `entries` against `known` (a list, or a zero-arity
  function returning one — evaluated at most once, and only when an entry
  needs it). Pure: logs nothing.
  """
  @spec resolve(list(), [known()] | (-> [known()])) :: [resolved()]
  def resolve(entries, known) when is_list(entries) do
    {resolved, _cache} = Enum.map_reduce(entries, known, &classify/2)
    resolved
  end

  @doc """
  Module-dispatch readers: the modules to call, in load order. A known plugin
  contributes its module, an unregistered loadable module itself; a dropped
  entry is logged (see the moduledoc) and contributes nothing.
  """
  @spec modules(list(), [known()] | (-> [known()]), module()) :: [module()]
  def modules(entries, known, reader) do
    entries
    |> resolve(known)
    |> Enum.flat_map(fn
      {:plugin, %{module: mod}} when is_atom(mod) and not is_nil(mod) -> [mod]
      {:plugin, other} -> warn(reader, other, :not_loadable)
      {:module, mod} -> [mod]
      {:drop, entry, reason} -> warn(reader, entry, reason)
    end)
  end

  @doc """
  Plugin-record readers: the known plugin records, in load order. An
  unregistered loadable module is skipped with a warning, as is every dropped
  entry.

  `warn: false` is for exactly one caller: `Registry.ResolverChain` running
  INSIDE the Registry process mid-registration, where a load-order name not
  yet registered is the boot sequence in progress, not a misconfiguration.
  """
  @spec plugins(list(), [known()] | (-> [known()]), module(), keyword()) :: [known()]
  def plugins(entries, known, reader, opts \\ []) do
    warn? = Keyword.get(opts, :warn, true)

    entries
    |> resolve(known)
    |> Enum.flat_map(fn
      {:plugin, k} -> [k]
      {:module, mod} -> if(warn?, do: warn(reader, mod, :unregistered_module), else: [])
      {:drop, entry, reason} -> if(warn?, do: warn(reader, entry, reason), else: [])
    end)
  end

  # ─── classification ─────────────────────────────────────────────────────

  defp classify(name, known) when is_binary(name) and name != "" do
    {known, list} = force(known)

    case Enum.find(list, &(&1.name == name)) do
      nil -> {{:drop, name, :unknown_name}, known}
      k -> {{:plugin, k}, known}
    end
  end

  defp classify({name, mod} = entry, known) when is_binary(name) and name != "" do
    {known, list} = force(known)

    cond do
      k = Enum.find(list, &(&1.name == name)) -> {{:plugin, k}, known}
      loadable?(mod) -> classify_module(mod, known)
      true -> {{:drop, entry, :unknown_name}, known}
    end
  end

  defp classify(mod, known) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) do
    if loadable?(mod), do: classify_module(mod, known), else: {{:drop, mod, :not_loadable}, known}
  end

  defp classify(other, known), do: {{:drop, other, :bad_shape}, known}

  defp classify_module(mod, known) do
    {known, list} = force(known)

    case Enum.find(list, &(&1.module == mod)) do
      nil -> {{:module, mod}, known}
      k -> {{:plugin, k}, known}
    end
  end

  # `known` may be a thunk; force it once and carry the list through the reduce.
  defp force(fun) when is_function(fun, 0), do: force(fun.())
  defp force(list) when is_list(list), do: {list, list}

  defp loadable?(mod) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod),
    do: Code.ensure_loaded?(mod)

  defp loadable?(_), do: false

  # ─── the loud drop ──────────────────────────────────────────────────────

  @doc false
  @spec reason_text(reason()) :: String.t()
  def reason_text(:unknown_name), do: "it names no plugin this reader knows"

  def reason_text(:unregistered_module),
    do:
      "it is a loadable module but not a registered plugin; this reader takes " <>
        "registered plugins only (Plugins.Hooks and Registry.BootCollectors DO run it)"

  def reason_text(:not_loadable), do: "it is not a loadable module"

  def reason_text(:bad_shape),
    do: "it is not a module, a {plugin_name, module} tuple, or a plugin-name string"

  defp warn(reader, entry, reason) do
    key = {__MODULE__, :warned, reader, entry}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "#{inspect(reader)}: skipping :barkpark, :plugins load-order entry " <>
          "#{inspect(entry, limit: 5)} — #{reason_text(reason)}"
      )
    end

    []
  end
end
