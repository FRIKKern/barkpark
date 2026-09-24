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
  name). Configured entries are interpreted by
  `Barkpark.Content.PluginLoadOrder.plugins/3` (task-3fbd48182b1d35ea): only
  a plugin that PUBLISHED a declaration contributes fences; a loadable module
  that never registered, an unknown name and a malformed entry are skipped with
  a `Logger.warning` naming them — never silently. (The "known" set here is the
  published declarations, and the Registry publishes one for EVERY registered
  plugin — an empty one when it declares no fences (task-a67de91e32edf1a4) —
  so a warning for a name means "no plugin is registered under it", never
  "that plugin declares nothing". The four sibling holders share the rule.)

  Freezing the order at publish time would let a registration made under a
  temporarily narrowed load order (a test's `with_plugins`) leave a fence list
  that outlives the narrowing.

  Cost per `list/0`: one `:persistent_term.get/2`, one `Application.get_env/3`
  and, under a configured order, one scan of the declarations per entry
  (`Code.ensure_loaded?/1` for a module entry) — no Repo read, no process call. Nothing published (the
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
      [_ | _] = configured ->
        configured
        |> Barkpark.Content.PluginLoadOrder.plugins(declared, __MODULE__)
        |> Enum.flat_map(& &1.fences)

      _ ->
        Enum.flat_map(declared, & &1.fences)
    end
  end

  @doc """
  Run `fences` in order, stopping at the first non-`:ok` and returning it
  UNCHANGED — exactly what the `with :ok <- Fence.check(...)` steps it replaced
  did, so no caller or test matching a fence's error shape sees a difference.

  ONE ordered list, no phases (task-2978357a0701cd10). Slice B needed an
  `:early` / `:late` split only because two writer-owned birth guards sat
  between the Tasks fences; they are Tasks fences now, so the list alone
  carries the order. The writer's two change guards (transition legality,
  close reason lands with a close) that ran just before this list are its
  first two entries since task-d91ccf54d43b9800, so the writer runs nothing
  task-specific around it.
  """
  @spec run([Barkpark.Plugin.pre_write_fence()], list()) :: :ok | term()
  def run(fences, args) do
    Enum.reduce_while(fences, :ok, fn {mod, fun}, :ok ->
      case apply(mod, fun, args) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end
end
