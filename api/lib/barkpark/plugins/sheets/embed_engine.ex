defmodule Barkpark.Plugins.Sheets.EmbedEngine do
  @moduledoc """
  The Sheets plugin's implementation of `Barkpark.Content.SheetEmbedEngine`
  (task-0b7e83682d7a7140), declared by `Barkpark.Plugins.Sheets.sheet_embed_engine/0`.
  The sheet save path recomputes formulas through `Engine.recompute/1`, and the
  embed write-through and hydration cache `Core.snapshot_for/2`.
  """

  @behaviour Barkpark.Content.SheetEmbedEngine

  alias Barkpark.Plugins.Sheets.{Core, Engine}

  @impl true
  def recompute(content), do: Engine.recompute(content)

  @impl true
  def snapshot_for(content, tab_index), do: Core.snapshot_for(content, tab_index)
end
