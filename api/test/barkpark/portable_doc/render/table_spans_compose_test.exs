defmodule Barkpark.PortableDoc.Render.TableSpansComposeTest do
  # Merged cells (Barkdown plan #24): `spans` on a table block ride PdTable after validation —
  # integers, inside the grid, clipped to it; anything else drops so the walker never sees an
  # entry it cannot honour. A table without spans composes exactly as before.
  use ExUnit.Case, async: true
  alias Barkpark.PortableDoc.Render.Compose

  @table %{
    "id" => "t",
    "type" => "table",
    "head" => [[%{"type" => "text", "value" => "A"}], [%{"type" => "text", "value" => "B"}], [%{"type" => "text", "value" => "C"}]],
    "rows" => [[[%{"type" => "text", "value" => "a"}], [], []], [[], [], []]]
  }

  test "no spans: no key on PdTable" do
    refute Map.has_key?(Compose.compose_block(@table, :article), "spans")
  end

  test "valid spans ride; malformed, out-of-grid and 1x1 entries drop; oversize ones clip to the grid" do
    spans = [
      %{"row" => 0, "col" => 0, "colspan" => 2, "rowspan" => 1},
      %{"row" => 1, "col" => 1, "colspan" => "9", "rowspan" => 1},
      %{"row" => 5, "col" => 0, "colspan" => 2},
      %{"row" => 0, "col" => 2, "colspan" => 1, "rowspan" => 1},
      "junk"
    ]

    pd = Compose.compose_block(Map.put(@table, "spans", spans), :article)

    assert pd["spans"] == [
             %{"row" => 0, "col" => 0, "colspan" => 2, "rowspan" => 1},
             %{"row" => 1, "col" => 1, "colspan" => 2, "rowspan" => 1}
           ]
  end

  test "the email arm never carries spans" do
    pd = Compose.compose_block(Map.put(@table, "spans", [%{"row" => 0, "col" => 0, "colspan" => 2}]), :email)
    assert pd["spans"] == [%{"row" => 0, "col" => 0, "colspan" => 2, "rowspan" => 1}] or not Map.has_key?(pd, "spans")
  end
end
