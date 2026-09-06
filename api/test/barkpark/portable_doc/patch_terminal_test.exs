defmodule Barkpark.PortableDoc.PatchTerminalTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  defp paragraph(id, text, extra \\ %{}) do
    Map.merge(%{"id" => id, "type" => "paragraph", "text" => text}, extra)
  end

  defp terminal(children, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "terminal",
        "type" => "terminal",
        "title" => "Shell",
        "unknown" => %{"keep" => true},
        "children" => children
      },
      extra
    )
  end

  test "patches, replaces, inserts, and removes only canonical terminal children" do
    first = paragraph("first", "Before", %{"meta" => [1, 2]})
    second = paragraph("second", "Second")
    before = [terminal([first, second])]

    assert {:ok, [patched]} =
             Patch.apply_patch(before, %{
               "op" => "patch-block",
               "id" => "first",
               "patch" => %{"id" => "evil", "text" => "After"}
             })

    assert patched["children"] == [
             paragraph("first", "After", %{"meta" => [1, 2]}),
             second
           ]

    assert patched["title"] == "Shell"
    assert patched["unknown"] == %{"keep" => true}

    replacement = %{"id" => "first", "type" => "code", "value" => "echo ok"}

    assert {:ok, [replaced]} =
             Patch.apply_patch(before, %{
               "op" => "replace-block",
               "id" => "first",
               "block" => replacement
             })

    assert replaced["children"] == [replacement, second]

    inserted = paragraph("inserted", "Inserted")

    assert {:ok, [with_insert]} =
             Patch.apply_patch(before, %{
               "op" => "insert-after",
               "afterId" => "first",
               "block" => inserted
             })

    assert with_insert["children"] == [first, inserted, second]

    assert {:ok, [removed]} =
             Patch.apply_patch(before, %{"op" => "remove-block", "id" => "first"})

    assert removed["children"] == [second]
    assert before == [terminal([first, second])]
  end

  test "canonical terminal descendants participate in locks and duplicate fencing" do
    locked = paragraph("locked", "Keep", %{"locked" => true})
    before = [terminal([paragraph("anchor", "A"), locked])]

    assert {:error, {:locked_block, "locked", "remove-block"}} =
             Patch.apply_patch(before, %{"op" => "remove-block", "id" => "locked"})

    assert {:error, {:locked_block, "locked", "replace-block"}} =
             Patch.apply_patch(before, %{
               "op" => "replace-block",
               "id" => "locked",
               "block" => paragraph("locked", "Replacement")
             })

    assert {:error, {:duplicate_id, "locked", "insert-after"}} =
             Patch.apply_patch(before, %{
               "op" => "insert-after",
               "afterId" => "anchor",
               "block" => paragraph("locked", "Duplicate")
             })
  end

  test "legacy and malformed terminal aliases stay untargetable and unchanged" do
    hidden = paragraph("hidden", "Hidden", %{"locked" => true})

    for block <- [
          terminal([hidden], %{"blocks" => []}),
          terminal([hidden], %{"blocks" => nil}),
          terminal([], %{"blocks" => [hidden]}),
          terminal(nil, %{"blocks" => [hidden]}),
          terminal("legacy"),
          Map.delete(terminal([hidden]), "children") |> Map.put("blocks", [hidden]),
          Map.delete(terminal([hidden]), "children")
        ] do
      before = [block]

      assert {:error, {:block_not_found, "hidden", "patch-block"}} =
               Patch.apply_patch(before, %{
                 "op" => "patch-block",
                 "id" => "hidden",
                 "patch" => %{"text" => "Exposed"}
               })

      assert {:ok, ^before} =
               Patch.apply_patch(before, %{"op" => "remove-block", "id" => "hidden"})

      assert {:error, {:block_not_found, "hidden", "replace-block"}} =
               Patch.apply_patch(before, %{
                 "op" => "replace-block",
                 "id" => "hidden",
                 "block" => paragraph("hidden", "Replacement")
               })

      assert {:error, {:block_not_found, "hidden", "insert-after"}} =
               Patch.apply_patch(before, %{
                 "op" => "insert-after",
                 "afterId" => "hidden",
                 "block" => paragraph("new", "New")
               })
    end
  end

  test "hidden terminal aliases reserve duplicate ids without becoming traversable" do
    hidden = [paragraph("reserved", "Hidden")]

    for block <- [
          terminal([], %{"blocks" => hidden}),
          Map.delete(terminal([], %{"blocks" => hidden}), "children")
        ] do
      assert {:error, {:duplicate_id, "reserved", "append-block"}} =
               Patch.apply_patch([block], %{
                 "op" => "append-block",
                 "block" => paragraph("reserved", "Outside")
               })
    end

    before = [terminal([], %{"blocks" => hidden})]

    assert {:error, {:duplicate_id, "reserved", "patch-block"}} =
             Patch.apply_patch(before, %{
               "op" => "patch-block",
               "id" => "terminal",
               "patch" => %{"children" => [paragraph("reserved", "Visible")]}
             })
  end

  test "nested canonical terminals recurse while legacy aliases below them remain opaque" do
    nested =
      terminal([
        %{
          "id" => "section",
          "type" => "section",
          "blocks" => [
            %{
              "id" => "inner",
              "type" => "terminal",
              "children" => [paragraph("deep", "Before")],
              "meta" => true
            }
          ]
        }
      ])

    assert {:ok, [changed]} =
             Patch.apply_patch([nested], %{
               "op" => "patch-block",
               "id" => "deep",
               "patch" => %{"text" => "After"}
             })

    assert get_in(changed, ["children", Access.at(0), "blocks", Access.at(0), "children"]) == [
             paragraph("deep", "After")
           ]

    legacy = put_in(nested, ["children", Access.at(0), "blocks", Access.at(0), "blocks"], [])

    assert {:error, {:block_not_found, "deep", "patch-block"}} =
             Patch.apply_patch([legacy], %{
               "op" => "patch-block",
               "id" => "deep",
               "patch" => %{"text" => "Exposed"}
             })
  end
end
