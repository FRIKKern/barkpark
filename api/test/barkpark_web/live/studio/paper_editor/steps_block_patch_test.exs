defmodule BarkparkWeb.Studio.PaperEditor.StepsBlockPatchTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "fresh steps default has stable row and editable paragraph identities" do
    assert Blocks.default_block("steps", "procedure") == %{
             "id" => "procedure",
             "type" => "steps",
             "steps" => [
               %{
                 "id" => "procedure-step-0",
                 "title" => "Step 1",
                 "blocks" => [
                   %{
                     "id" => "procedure-step-0-0",
                     "type" => "paragraph",
                     "content" => [%{"type" => "text", "value" => ""}]
                   }
                 ]
               }
             ]
           }
  end

  test "updates titles by stable submitted identity and preserves complete row maps" do
    first = %{
      "id" => "row-a",
      "title" => 42,
      "children" => [%{"id" => "body-a", "type" => "paragraph", "text" => "Keep"}],
      "blocks" => [%{"id" => "shadow", "type" => "paragraph"}],
      "unknown" => %{"keep" => true}
    }

    second = %{"id" => "row-b", "title" => "Second", "blocks" => []}
    block = steps([first, second])

    assert {:ok, %{"steps" => [updated, ^second]}} =
             Blocks.validate_block_patch(block, wire([{"row-a", "First"}, {"row-b", "Second"}]))

    assert updated == %{first | "title" => "First"}

    assert {:ok, %{}} =
             Blocks.validate_block_patch(block, wire([{"row-a", "42"}, {"row-b", "Second"}]))
  end

  test "rejects stale identity ordering, missing fields, duplicates, and unknown actions" do
    block = steps([row("row-a"), row("row-b")])

    for params <- [
          wire([{"row-b", ""}, {"row-a", ""}]),
          Map.delete(wire([{"row-a", ""}, {"row-b", ""}]), "step-1-title"),
          Map.put(wire([{"row-a", ""}, {"row-b", ""}]), "step-0-title", %{"bad" => true}),
          wire([{"row-a", ""}, {"row-a", ""}]),
          Map.put(wire([{"row-a", ""}, {"row-b", ""}]), "step-2-id", "extra"),
          Map.put(wire([{"row-a", ""}, {"row-b", ""}]), "step-action", "sideways:row-a")
        ] do
      assert {:error, {:malformed_collection, "steps"}} =
               Blocks.validate_block_patch(block, params)
    end
  end

  test "adds, removes, and moves whole rows by id without position-derived identity" do
    first = Map.put(row("row-a"), "unknown", "keep-a")
    second = Map.put(row("row-b"), "unknown", "keep-b")
    block = steps([first, second])
    base = wire([{"row-a", ""}, {"row-b", ""}])

    assert {:ok, %{"steps" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, Map.put(base, "step-action", "up:row-b"))

    assert {:ok, %{"steps" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, Map.put(base, "step-action", "down:row-a"))

    assert {:ok, %{}} =
             Blocks.validate_block_patch(block, Map.put(base, "step-action", "up:row-a"))

    assert {:ok, %{"steps" => [^second]}} =
             Blocks.validate_block_patch(block, Map.put(base, "step-action", "remove:row-a"))

    add =
      base
      |> Map.put("step-action", "add")
      |> Map.put("step-new-row-id", "row-new")

    assert {:ok, %{"steps" => [^first, ^second, added]}} =
             Blocks.validate_block_patch(block, add)

    assert added == %{"id" => "row-new", "title" => "", "blocks" => []}
  end

  test "refuses removing a row that would delete a locked descendant" do
    locked = %{"id" => "locked-child", "type" => "paragraph", "locked" => true}
    block = steps([Map.put(row("row-a"), "blocks", [locked]), row("row-b")])

    params =
      [{"row-a", ""}, {"row-b", ""}]
      |> wire()
      |> Map.put("step-action", "remove:row-a")

    assert {:error, {:locked_block, "locked-child", "remove-block"}} =
             Blocks.validate_block_patch(block, params)
  end

  test "adds the first paragraph through the renderer-visible alias only" do
    for {body, key} <- [
          {%{"children" => [], "blocks" => [%{"id" => "shadow", "type" => "code"}]}, "children"},
          {%{"children" => nil, "blocks" => []}, "blocks"},
          {%{"children" => false}, "blocks"},
          {%{}, "blocks"}
        ] do
      original = Map.merge(row("row-a"), body)
      block = steps([original])

      params =
        [{"row-a", ""}]
        |> wire()
        |> Map.put("step-action", "add-body:row-a")
        |> Map.put("step-new-child-id", "body-new")

      assert {:ok, %{"steps" => [updated]}} = Blocks.validate_block_patch(block, params)

      assert Map.fetch!(updated, key) == [
               %{
                 "id" => "body-new",
                 "type" => "paragraph",
                 "content" => [%{"type" => "text", "value" => ""}]
               }
             ]

      for shadow_key <- ["children", "blocks"], shadow_key != key do
        assert Map.get(updated, shadow_key) == Map.get(original, shadow_key)
      end
    end
  end

  test "refuses first-body creation for nonempty or malformed visible bodies" do
    params =
      [{"row-a", ""}]
      |> wire()
      |> Map.put("step-action", "add-body:row-a")
      |> Map.put("step-new-child-id", "body-new")

    for body <- [
          %{"children" => [%{"id" => "existing", "type" => "paragraph"}]},
          %{"children" => %{}, "blocks" => []},
          %{"children" => "invalid", "blocks" => []},
          %{"blocks" => %{}}
        ] do
      assert {:error, {:malformed_collection, "steps"}} =
               Blocks.validate_block_patch(steps([Map.merge(row("row-a"), body)]), params)
    end
  end

  test "rejects malformed stored rows and new identity collisions without rewriting legacy shape" do
    base = wire([{"row-a", ""}])

    assert {:error, {:malformed_collection, "steps"}} =
             Blocks.validate_block_patch(
               steps([row("row-a"), "legacy"]),
               Map.put(base, "step-count", "2")
             )

    for {action, field, collision} <- [
          {"add", "step-new-row-id", "row-a"},
          {"add", "step-new-row-id", "body-a"},
          {"add-body:row-a", "step-new-child-id", "row-a"},
          {"add-body:row-a", "step-new-child-id", "body-a"}
        ] do
      block = steps([Map.put(row("row-a"), "blocks", [%{"id" => "body-a", "type" => "code"}])])

      params =
        base
        |> Map.put("step-action", action)
        |> Map.put(field, collision)

      assert {:error, {:duplicate_id, ^collision}} = Blocks.validate_block_patch(block, params)
    end
  end

  defp steps(rows), do: %{"id" => "steps", "type" => "steps", "steps" => rows}
  defp row(id), do: %{"id" => id, "title" => "", "blocks" => []}

  defp wire(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(%{"step-count" => Integer.to_string(length(rows))}, fn {{id, title}, index},
                                                                          acc ->
      acc
      |> Map.put("step-#{index}-id", id)
      |> Map.put("step-#{index}-title", title)
    end)
  end
end
