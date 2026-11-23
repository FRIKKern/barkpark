defmodule Barkpark.Groq.PortableTextListItemTest do
  @moduledoc """
  Search text (`pt::text` over a richText Paper, `PortableText.doc_text/1`)
  holds what the reader shows of a list item, not a `text` it does not show:
  an item with words in `content` keeps its `text` out of search, as the
  reader keeps it off the page (task-0b448ea0847a6b4f).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.PortableText

  @golden Path.expand(
            "../../../priv/portable_doc/goldens/nested-list-carriers.json",
            __DIR__
          )

  test "search text does not read a text the reader does not show" do
    blocks = @golden |> File.read!() |> Jason.decode!() |> Map.fetch!("blocks")
    [%{"items" => [plan | _]}] = blocks
    assert plan["text"] == "Inactive parent fallback"

    search = PortableText.doc_text(blocks)

    assert search =~ "Plan"
    refute search =~ "Inactive"
  end
end
