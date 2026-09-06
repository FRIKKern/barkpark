defmodule BarkparkWeb.Studio.PaperEditor.TabsBlockPatchTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "fresh tabs default has stable row and paragraph identities" do
    assert Blocks.default_block("tabs", "switcher") == %{
             "id" => "switcher",
             "type" => "tabs",
             "tabs" => [
               %{
                 "id" => "switcher-tab-0",
                 "label" => "Tab 1",
                 "blocks" => [
                   %{
                     "id" => "switcher-tab-0-0",
                     "type" => "paragraph",
                     "content" => [%{"type" => "text", "value" => ""}]
                   }
                 ]
               }
             ]
           }
  end

  test "updates labels by stable submitted identity and preserves complete row maps" do
    first = %{
      "id" => "row-a",
      "label" => "First old",
      "blocks" => [%{"id" => "body-a", "type" => "paragraph", "text" => "Keep"}],
      "children" => [%{"id" => "opaque", "locked" => true}],
      "content" => %{"opaque" => true},
      "unknown" => %{"keep" => true}
    }

    second = row("row-b", "Second")
    block = tabs([first, second])

    assert {:ok, %{"tabs" => [updated, ^second]}} =
             Blocks.validate_block_patch(block, wire([{"row-a", "First"}, {"row-b", "Second"}]))

    assert updated == %{first | "label" => "First"}

    assert {:ok, %{}} =
             Blocks.validate_block_patch(
               block,
               wire([{"row-a", "First old"}, {"row-b", "Second"}])
             )
  end

  test "rows with blank identities or nontext labels remain read-only" do
    for row <- [
          %{"id" => "   ", "label" => "Blank id", "blocks" => []},
          %{"id" => "row", "label" => 42, "blocks" => []},
          %{"id" => "row", "label" => %{"bad" => true}, "blocks" => []}
        ] do
      assert {:error, {:malformed_collection, "tabs"}} =
               Blocks.validate_block_patch(tabs([row]), wire([{row["id"], "Edited"}]))
    end

    nil_label = %{"id" => "row", "label" => nil, "blocks" => []}
    assert {:ok, %{}} = Blocks.validate_block_patch(tabs([nil_label]), wire([{"row", ""}]))
  end

  test "rejects stale identity ordering, missing fields, duplicates, nontext labels, and unknown params" do
    block = tabs([row("row-a"), row("row-b")])

    for params <- [
          wire([{"row-b", ""}, {"row-a", ""}]),
          Map.delete(wire([{"row-a", ""}, {"row-b", ""}]), "panel-1-label"),
          Map.put(wire([{"row-a", ""}, {"row-b", ""}]), "panel-0-label", %{"bad" => true}),
          wire([{"row-a", ""}, {"row-a", ""}]),
          Map.put(wire([{"row-a", ""}, {"row-b", ""}]), "panel-2-id", "extra"),
          Map.put(wire([{"row-a", ""}, {"row-b", ""}]), "panel-action", "sideways:row-a")
        ] do
      assert {:error, {:malformed_collection, "tabs"}} =
               Blocks.validate_block_patch(block, params)
    end
  end

  test "adds, removes, and moves whole rows by stable id" do
    first = Map.put(row("row-a"), "unknown", "keep-a")
    second = Map.put(row("row-b"), "unknown", "keep-b")
    block = tabs([first, second])
    base = wire([{"row-a", ""}, {"row-b", ""}])

    assert {:ok, %{"tabs" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, Map.put(base, "panel-action", "up:row-b"))

    assert {:ok, %{"tabs" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, Map.put(base, "panel-action", "down:row-a"))

    assert {:ok, %{}} =
             Blocks.validate_block_patch(block, Map.put(base, "panel-action", "up:row-a"))

    assert {:ok, %{"tabs" => [^second]}} =
             Blocks.validate_block_patch(block, Map.put(base, "panel-action", "remove:row-a"))

    add =
      base
      |> Map.put("panel-action", "add")
      |> Map.put("panel-new-row-id", "row-new")

    assert {:ok, %{"tabs" => [^first, ^second, added]}} =
             Blocks.validate_block_patch(block, add)

    assert added == %{"id" => "row-new", "label" => "", "blocks" => []}
  end

  test "missing and nil tabs are editable empty collections while malformed shapes remain read-only" do
    add = %{
      "panel-count" => "0",
      "panel-action" => "add",
      "panel-new-row-id" => "row-new"
    }

    for block <- [Map.delete(tabs([]), "tabs"), Map.put(tabs([]), "tabs", nil)] do
      assert {:ok, %{"tabs" => [%{"id" => "row-new", "label" => "", "blocks" => []}]}} =
               Blocks.validate_block_patch(block, add)
    end

    for malformed <- [
          %{},
          "legacy",
          true,
          [nil],
          [%{"id" => "row", "blocks" => false}],
          [%{"id" => "row", "blocks" => ["legacy"]}]
        ] do
      block = Map.put(tabs([]), "tabs", malformed)

      assert {:error, {:malformed_collection, "tabs"}} =
               Blocks.validate_block_patch(
                 block,
                 Map.put(add, "panel-count", submitted_count(malformed))
               )
    end
  end

  test "removal refuses locked canonical descendants but ignores opaque children and content" do
    locked = %{"id" => "locked-child", "type" => "paragraph", "locked" => true}
    canonical = tabs([Map.put(row("row-a"), "blocks", [locked]), row("row-b")])
    params = wire([{"row-a", ""}, {"row-b", ""}]) |> Map.put("panel-action", "remove:row-a")

    assert {:error, {:locked_block, "locked-child", "remove-block"}} =
             Blocks.validate_block_patch(canonical, params)

    opaque =
      tabs([
        row("row-a")
        |> Map.put("children", [locked])
        |> Map.put("content", [locked]),
        row("row-b")
      ])

    assert {:ok, %{"tabs" => [remaining]}} = Blocks.validate_block_patch(opaque, params)
    assert remaining["id"] == "row-b"
  end

  test "adds first canonical paragraph only to absent, nil, or empty blocks" do
    params =
      [{"row-a", ""}]
      |> wire()
      |> Map.put("panel-action", "add-body:row-a")
      |> Map.put("panel-new-child-id", "body-new")

    for body <- [%{}, %{"blocks" => nil}, %{"blocks" => []}] do
      original = Map.merge(row("row-a"), body)

      assert {:ok, %{"tabs" => [updated]}} =
               Blocks.validate_block_patch(tabs([original]), params)

      assert updated["blocks"] == [
               %{
                 "id" => "body-new",
                 "type" => "paragraph",
                 "content" => [%{"type" => "text", "value" => ""}]
               }
             ]

      assert Map.drop(updated, ["blocks"]) == Map.drop(original, ["blocks"])
    end

    for body <- [false, "bad", %{}, [%{"id" => "existing", "type" => "paragraph"}]] do
      block = tabs([Map.put(row("row-a"), "blocks", body)])

      assert {:error, {:malformed_collection, "tabs"}} =
               Blocks.validate_block_patch(block, params)
    end
  end

  test "new identities reject canonical collisions without interpreting opaque metadata" do
    block =
      tabs([
        row("row-a")
        |> Map.put("blocks", [%{"id" => "body-a", "type" => "paragraph"}])
        |> Map.put("children", [%{"id" => "opaque"}])
        |> Map.put("content", [%{"id" => "opaque-content"}])
      ])

    base = wire([{"row-a", ""}])

    for {action, field, collision} <- [
          {"add", "panel-new-row-id", "row-a"},
          {"add", "panel-new-row-id", "body-a"},
          {"add-body:row-a", "panel-new-child-id", "row-a"},
          {"add-body:row-a", "panel-new-child-id", "body-a"}
        ] do
      params = base |> Map.put("panel-action", action) |> Map.put(field, collision)
      assert {:error, {:duplicate_id, ^collision}} = Blocks.validate_block_patch(block, params)
    end

    assert {:ok, %{"tabs" => [_old, %{"id" => "opaque"}]}} =
             Blocks.validate_block_patch(
               block,
               base
               |> Map.put("panel-action", "add")
               |> Map.put("panel-new-row-id", "opaque")
             )

    malformed_nested = %{
      "id" => "malformed-tabs",
      "type" => "tabs",
      "tabs" => "legacy",
      "blocks" => [%{"id" => "decoy", "type" => "paragraph"}]
    }

    block = tabs([Map.put(row("row-a"), "blocks", [malformed_nested])])

    assert {:ok, %{"tabs" => [_old, %{"id" => "decoy"}]}} =
             Blocks.validate_block_patch(
               block,
               wire([{"row-a", ""}])
               |> Map.put("panel-action", "add")
               |> Map.put("panel-new-row-id", "decoy")
             )
  end

  defp tabs(rows), do: %{"id" => "tabs", "type" => "tabs", "tabs" => rows}
  defp row(id, label \\ ""), do: %{"id" => id, "label" => label, "blocks" => []}

  defp wire(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(%{"panel-count" => Integer.to_string(length(rows))}, fn {{id, label}, index},
                                                                           acc ->
      acc
      |> Map.put("panel-#{index}-id", id)
      |> Map.put("panel-#{index}-label", label)
    end)
  end

  defp submitted_count(value) when is_list(value), do: Integer.to_string(length(value))
  defp submitted_count(_value), do: "0"
end
