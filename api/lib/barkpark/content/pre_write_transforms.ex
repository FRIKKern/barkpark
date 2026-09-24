defmodule Barkpark.Content.PreWriteTransforms do
  @moduledoc """
  The content-owned holder for plugin pre-write transforms
  (`Barkpark.Plugin.pre_write_transforms/0`, task-aed4f02e57d3a760).

  The attrs-shaping twin of `Barkpark.Content.PreWriteFences`, built the same
  way for the same reason: THE DEPENDENCY POINTS INTO CONTENT, NEVER OUT OF
  IT. `Barkpark.Content.Writer` must not name `Barkpark.Plugins.Registry`
  (kernel→feature; `tooling/concept-map/ci-boundary.mjs` reds that edge), so
  the Registry PUBLISHES each registered plugin's declared steps here
  (`publish/1`, on every register / reset and at Registry init) and the writer
  only ever reads this module.

  What is stored is each plugin's declaration, NOT a pre-ordered list: `list/0`
  applies the `:barkpark, :plugins` load order at READ time, the same
  precedence as `PreWriteFences.list/0`, and through the same interpreter,
  `Barkpark.Content.PluginLoadOrder.plugins/3` (task-21f5264a452b7cf9): an
  entry that published no declaration (a loadable module that never
  registered, an unknown name, a malformed entry) is skipped with a
  `Logger.warning` naming it — never silently.

  Nothing published (the `BARKPARK_PLUGINS=""` kill switch registers nothing;
  Registry init publishes `[]`) resolves `[]`, and `run/3` returns the attrs
  it was given, untouched.

  WHERE IT RUNS. At the last step of the writer's attrs pipeline on BOTH write
  doors — `create_document/4` (after `maybe_ensure_block_ids/1`) and
  `upsert_document/4` (after the paper body_html scrub) — which is where the
  writer called `BriefMirror.maybe_resync_task_brief/2` and then
  `validate_task_kind/2` when it named them. That is BEFORE the prev-doc read,
  the label-spine shape gate and every `PreWriteFences` fence.

  TWO KINDS OF STEP, in one declared order:

    * `:transform` — `apply(mod, fun, [attrs, type])`, returns the attrs
      (unchanged when not applicable). The next step sees its output.
    * `:check` — `apply(mod, fun, [type, attrs])`, returns `:ok` or a
      refusal, which `run/3` returns VERBATIM and stops.

  A `:check` lives here rather than in `PreWriteFences` when it must judge the
  TRANSFORMED attrs at THIS position: a fence runs later (after the prev-doc
  read, inside the create door's connection-rescue region, after the label
  spine gate), so moving a check there changes which refusal a write that
  trips two gates receives.
  """

  @key {__MODULE__, :declared}

  @typedoc "One registered plugin's declaration."
  @type declared :: %{
          name: String.t(),
          module: module(),
          steps: [Barkpark.Plugin.pre_write_transform()]
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

  @doc "The steps to run, in plugin load order (each plugin's own order kept)."
  @spec list() :: [Barkpark.Plugin.pre_write_transform()]
  def list do
    declared = :persistent_term.get(@key, [])

    case Application.get_env(:barkpark, :plugins, []) do
      [_ | _] = configured ->
        configured
        |> Barkpark.Content.PluginLoadOrder.plugins(declared, __MODULE__)
        |> Enum.flat_map(& &1.steps)

      _ ->
        Enum.flat_map(declared, & &1.steps)
    end
  end

  @doc """
  Run `steps` in order over `attrs`. Returns `{:ok, attrs}` with every
  `:transform` applied, or the first `:check` refusal UNCHANGED — exactly what
  the `with :ok <- validate_task_kind(type, attrs)` step it replaced returned,
  so no caller or test matching that error shape sees a difference.
  """
  @spec run([Barkpark.Plugin.pre_write_transform()], String.t(), map()) ::
          {:ok, map()} | term()
  def run(steps, type, attrs) do
    Enum.reduce_while(steps, {:ok, attrs}, fn
      {:transform, mod, fun}, {:ok, acc} ->
        {:cont, {:ok, apply(mod, fun, [acc, type])}}

      {:check, mod, fun}, {:ok, acc} ->
        case apply(mod, fun, [type, acc]) do
          :ok -> {:cont, {:ok, acc}}
          refusal -> {:halt, refusal}
        end
    end)
  end
end
