defmodule Barkpark.Content.PrePublishFences do
  @moduledoc """
  The content-owned holder for plugin pre-publish fences
  (`Barkpark.Plugin.pre_publish_fences/0`, task-8273f2f1b24a6de1).

  The publish-door twin of `Barkpark.Content.PreWriteFences`, and built the
  same way for the same reason: THE DEPENDENCY POINTS INTO CONTENT, NEVER OUT
  OF IT. `Barkpark.Content.Lifecycle` must not name `Barkpark.Plugins.Registry`
  (kernel→feature; `tooling/concept-map/ci-boundary.mjs` reds that edge), so
  the Registry PUBLISHES each registered plugin's declared publish fences here
  (`publish/1`, on every register / reset and at Registry init) and the
  lifecycle only ever reads this module.

  What is stored is each plugin's declaration, NOT a pre-ordered list: `list/0`
  applies the `:barkpark, :plugins` load order at READ time, the same
  precedence as `PreWriteFences.list/0` and
  `Barkpark.Plugins.Registry.ResolverChain.load_ordered_plugins/0`, and through
  the same interpreter, `Barkpark.Content.PluginLoadOrder.plugins/3`: an entry
  that published no declaration (a loadable module that never registered, an
  unknown name, a malformed entry) is skipped with a `Logger.warning` naming it.

  Nothing published (the `BARKPARK_PLUGINS=""` kill switch registers nothing;
  Registry init publishes `[]`) resolves `[]`, and a publish runs no fence at
  all.

  TWO PHASES, because the gates this seam carries sit at two places in
  `Content.Lifecycle`'s publish, on opposite sides of the transaction:

    * `:door` — immediately after the draft read and the core render-shape and
      title gates, BEFORE the authoring wall, the `:before_publish` hook chain
      and the transaction, so a refusal is side-effect-free. Returned verbatim
      out of the publish `with`.
    * `:in_transaction` — inside the publish transaction, right after the
      incumbent published row is locked `FOR UPDATE`, before the update. A
      refusal rolls the transaction back (`Repo.rollback(reason)`), so the
      caller sees the same `{:error, reason}` the door would have returned.

  One phase could not hold both: putting the door gate inside the transaction
  would move it behind the wall, the hooks and the in-transaction dedup
  re-check (changing which refusal a publish that trips two of them receives,
  and letting a hook run for a publish the gate refuses); putting the
  in-transaction re-check at the door would lose the lock it exists to read
  under (see the Tasks plugin's `tasks/publish_guards.ex`).
  """

  @key {__MODULE__, :declared}

  @typedoc "One registered plugin's declaration."
  @type declared :: %{
          name: String.t(),
          module: module(),
          fences: [Barkpark.Plugin.pre_publish_fence()]
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
  @spec list() :: [Barkpark.Plugin.pre_publish_fence()]
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
  Run one phase of `fences` in order, stopping at the first non-`:ok` and
  returning it UNCHANGED — exactly what the direct gate calls it replaced
  returned, so no caller or test matching a gate's error shape sees a
  difference. Fences of the other phase are skipped.
  """
  @spec run(
          [Barkpark.Plugin.pre_publish_fence()],
          Barkpark.Plugin.pre_publish_fence_phase(),
          list()
        ) ::
          :ok | term()
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
