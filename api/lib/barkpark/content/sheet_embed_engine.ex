defmodule Barkpark.Content.SheetEmbedEngine do
  @moduledoc """
  The content-owned seam through which the sheet save path and the sheet embed
  pipeline (`Barkpark.Content.Sheets`) reach the spreadsheet engine
  (task-0b7e83682d7a7140, Barkspark phase 1 slice K): formula recompute on a
  sheet save, and the dense snapshot a `{"type":"sheet","ref":…}` block caches.

  Built like `Barkpark.Content.PaperTaskResolver` and
  `Barkpark.Content.ResolveDocGuards`, for the same reason: the dependency
  points into content, never out of it. `Content.Sheets` must not name a
  plugin, so a plugin declares an engine module through
  `Barkpark.Plugin.sheet_embed_engine/0`, the Registry PUBLISHES every
  registered plugin's declaration here (`publish/1`, on every register / reset
  and at Registry init), and content only ever calls `recompute/1` and
  `snapshot_for/2`. The Sheets plugin is the one declarer today.

  `get/0` applies the `:barkpark, :plugins` load order at READ time through
  `Barkpark.Content.PluginLoadOrder.plugins/3`, and the FIRST declared engine
  wins.

  NO ENGINE — nothing published (the `BARKPARK_PLUGINS=""` kill switch
  registers nothing; Registry init publishes `[]`) or the Sheets plugin is out
  of the load order. Both calls then degrade instead of raising:
  `recompute/1` returns the content unchanged (a sheet saves with the formula
  values it was sent), and `snapshot_for/2` returns `nil`, which the embed
  pipeline reads as "leave the block's cached snapshot as it is". An embed
  keeps rendering its last snapshot; it stops refreshing until an engine is
  registered again.

  NOT filtered by per-workspace enablement: a cached snapshot is what readers
  see, and switching the plugin off for one workspace must not freeze the
  embeds of sheets that are still being saved there.
  """

  @key {__MODULE__, :declared}

  @doc "Recompute every formula cell in a sheet's content; total and pure."
  @callback recompute(content :: map()) :: map()

  @doc "The dense value snapshot of one tab of a sheet's content."
  @callback snapshot_for(content :: term(), tab_index :: non_neg_integer()) :: map()

  @typedoc "One registered plugin's declaration."
  @type declared :: %{name: String.t(), module: module(), engine: module() | nil}

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

  @doc "The engine module (registered and in the load order), or `nil`."
  @spec get() :: module() | nil
  def get do
    declared = :persistent_term.get(@key, [])

    case Application.get_env(:barkpark, :plugins, []) do
      [_ | _] = configured ->
        Barkpark.Content.PluginLoadOrder.plugins(configured, declared, __MODULE__)

      _ ->
        declared
    end
    |> Enum.find_value(& &1.engine)
  end

  @doc """
  Recompute a sheet's formulas through the engine. With no engine the content
  comes back unchanged.
  """
  @spec recompute(map()) :: map()
  def recompute(content) do
    case get() do
      nil -> content
      engine -> engine.recompute(content)
    end
  end

  @doc """
  The snapshot one embed block caches for `tab_index` of a sheet's content, or
  `nil` when no engine is registered (the caller keeps the block unchanged).
  """
  @spec snapshot_for(term(), non_neg_integer()) :: map() | nil
  def snapshot_for(content, tab_index) do
    case get() do
      nil -> nil
      engine -> engine.snapshot_for(content, tab_index)
    end
  end
end
