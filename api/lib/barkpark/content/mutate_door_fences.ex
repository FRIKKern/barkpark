defmodule Barkpark.Content.MutateDoorFences do
  @moduledoc """
  The content-owned holder for plugin mutate-door fences
  (`Barkpark.Plugin.mutate_door_fences/0`, task-b04cbe7823d084a6).

  Built like `Barkpark.Content.PreWriteFences`, for the same reason: THE
  DEPENDENCY POINTS INTO CONTENT, NEVER OUT OF IT. `Barkpark.Content.Mutations`
  must not name a feature, so the Registry PUBLISHES each registered plugin's
  declared fences here (`publish/1`, on every register / reset and at Registry
  init) and the mutate door only ever reads this module. Nothing published
  (the `BARKPARK_PLUGINS=""` kill switch registers nothing; Registry init
  publishes `[]`) resolves `[]`, and `run/3` is `:ok`.

  WHY A THIRD FENCE LIST AND NOT `PreWriteFences` (measured, not assumed). The
  guards this list carries judge a RAW `/v1/data/mutate` write, and the writer's
  fences cannot see what they need:

    * the ROW. A `patch` on a bare published `type:task` id resolves its base
      PUBLISHED-first, but `Writer.upsert_document/4` always reads
      `drafts.<id>` as its `prev_doc`. A probe fence in `PreWriteFences` saw
      `prev_doc = nil` for exactly that write while the mutate door held the
      published row — and every change guard here heads on
      `(_, nil, …) -> :ok`, so moved into the writer it would pass the most
      common target silently.
    * the ORDER. The writer runs its own refusals (bare id, orphan keys,
      colliding status, the `pre_write_transforms/0` checks, the label spine)
      before any fence. A raw patch that changes `disposition` AND carries a
      bad `priority` is refused on `disposition` here; in the writer it would
      be refused on `priority`.
    * the DOOR. The writer is also reached by the legacy controller, the
      Studio and every internal caller, most with `source: :api` or no source
      at all. These guards are specific to the mutate door; running them here
      keeps that condition structural, exactly as it was.

  TWO PHASES, because the guards sat at two positions in `apply_one/3`:

    * `:before_rev` — the create family's first step (`create`,
      `createOrReplace`, `createIfNotExists`), before `ensure_rev/2` and every
      other guard. The published-fork fence sits here: a create onto a
      published task somebody holds is refused as a fork before its revision
      is ever compared. The legacy create door runs this phase too, through
      `Mutations.ensure_create_not_forking_published_task/4`.
    * `:after_claim` — after the mutate door's own close-CAS and claim fences,
      directly before the writer call, on `createOrReplace`, `replace` and both
      `patch` clauses. The adjudication guards sit here.

  One phase could not hold both without moving the fork fence past
  `ensure_rev/2` and the claim fences (a create that forks a claimed row and
  carries a stale revision would change refusal), or moving the adjudication
  guards ahead of them.

  Every fence is called as
  `apply(module, function, [type, existing, merged, op, dataset, opts])`:
  `existing` is the row the mutate door resolved (or `nil`), `merged` the
  content the write will carry, `op` the raw mutation payload (attrs for the
  create family, the patch map for `patch`), `dataset` and `opts` as the door
  received them. Any non-`:ok` return is returned VERBATIM.

  LOAD ORDER. `list/0` applies the `:barkpark, :plugins` load order at READ
  time (a configured list wins, in its order; otherwise alphabetical by plugin
  name) through the same interpreter as `PreWriteFences.list/0`,
  `Barkpark.Content.PluginLoadOrder.plugins/3`: an entry that published no
  declaration (a loadable module that never registered, an unknown name, a
  malformed entry) is skipped with a `Logger.warning` naming it — never
  silently.
  """

  @key {__MODULE__, :declared}

  @typedoc "One registered plugin's declaration."
  @type declared :: %{
          name: String.t(),
          module: module(),
          fences: [Barkpark.Plugin.mutate_door_fence()]
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
  @spec list() :: [Barkpark.Plugin.mutate_door_fence()]
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
  returning it UNCHANGED — exactly what the `with :ok <- ensure_*(...)` steps
  it replaced did, so no caller or test matching a guard's error shape sees a
  difference. Fences of the other phase are skipped.
  """
  @spec run(
          [Barkpark.Plugin.mutate_door_fence()],
          Barkpark.Plugin.mutate_door_fence_phase(),
          list()
        ) :: :ok | term()
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
