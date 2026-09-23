defmodule Barkpark.Content.PreWriteFences do
  @moduledoc """
  The content-owned holder for plugin pre-write fences
  (`Barkpark.Plugin.pre_write_fences/0`, task-e5baaaa14ddf2e1c).

  THE DEPENDENCY POINTS INTO CONTENT, NEVER OUT OF IT. `Barkpark.Content.Writer`
  must not name `Barkpark.Plugins.Registry` — content is the kernel, the
  registry a feature, and `tooling/concept-map/ci-boundary.mjs` reds a new
  kernel→feature edge. So the Registry PUBLISHES each registered plugin's
  declared fences here (`publish/1`, on every register / reset and at Registry
  init) and the writer only ever reads this module.

  What is stored is each plugin's declaration, NOT a pre-ordered list: `list/0`
  applies the `:barkpark, :plugins` load order at READ time, the same
  precedence as `Barkpark.Plugins.Registry.ResolverChain.load_ordered_plugins/0`
  (a configured list wins, in its order; otherwise alphabetical by plugin
  name). Freezing the order at publish time would let a registration made
  under a temporarily narrowed load order (a test's `with_plugins`) leave a
  fence list that outlives the narrowing.

  Cost per `list/0`: one `:persistent_term.get/2` and one `Application.get_env/3`
  — no Repo read, no process call. Nothing published (the
  `BARKPARK_PLUGINS=""` kill switch registers nothing; Registry init publishes
  `[]`) resolves `[]`, and the writer runs no fence at all.
  """

  @key {__MODULE__, :declared}

  @typedoc "One registered plugin's declaration."
  @type declared :: %{
          name: String.t(),
          module: module(),
          fences: [Barkpark.Plugin.pre_write_fence()]
        }

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

  @doc "The fences to run, in plugin load order (each plugin's own order kept)."
  @spec list() :: [Barkpark.Plugin.pre_write_fence()]
  def list do
    declared = :persistent_term.get(@key, [])

    case Application.get_env(:barkpark, :plugins, []) do
      [_ | _] = configured -> Enum.flat_map(configured, &fences_for(declared, &1))
      _ -> Enum.flat_map(declared, & &1.fences)
    end
  end

  defp fences_for(declared, name) when is_binary(name), do: by(declared, :name, name)
  defp fences_for(declared, {name, _mod}) when is_binary(name), do: by(declared, :name, name)
  defp fences_for(declared, mod) when is_atom(mod), do: by(declared, :module, mod)
  defp fences_for(_declared, _other), do: []

  defp by(declared, field, value) do
    case Enum.find(declared, &(Map.fetch!(&1, field) == value)) do
      nil -> []
      entry -> entry.fences
    end
  end

  @doc """
  Run one phase of `fences` in order, stopping at the first non-`:ok` and
  returning it UNCHANGED — exactly what the `with :ok <- Fence.check(...)`
  steps it replaced did, so no caller or test matching a fence's error shape
  sees a difference.
  """
  @spec run([Barkpark.Plugin.pre_write_fence()], :early | :late, list()) :: :ok | term()
  def run(fences, phase, args) do
    Enum.reduce_while(fences, :ok, fn
      {^phase, mod, fun}, :ok ->
        case apply(mod, fun, args) do
          :ok -> {:cont, :ok}
          refusal -> {:halt, refusal}
        end

      _other_phase, :ok ->
        {:cont, :ok}
    end)
  end
end
