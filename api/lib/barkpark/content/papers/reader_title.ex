defmodule Barkpark.Content.Papers.ReaderTitle do
  @moduledoc """
  The title a reader of a Paper is shown.

  A Paper's stored title comes from its first heading when nothing else names
  it (`BlockOps.paper_title/2`). A reader is shown the first heading of the
  blocks they may see, else the slug. A stored title that does not come from
  the first heading, or that the reader's blocks still give, is shown as
  stored. Pure: no statement.
  """

  alias Barkpark.Content.Papers.BlockOps

  @doc """
  The title for a reader shown `shown_blocks` of a Paper stored as `title`
  over `stored_blocks`. `shown_blocks` is `nil` when the reader may see no
  block at all.
  """
  @spec of(String.t() | nil, [map()] | nil, [map()] | nil, String.t()) :: String.t() | nil
  def of(title, stored_blocks, shown_blocks, slug) do
    from_heading? = is_binary(title) and title == BlockOps.heading_title(stored_blocks || [])

    if from_heading?,
      do: BlockOps.heading_title(shown_blocks || []) || slug,
      else: title
  end
end
