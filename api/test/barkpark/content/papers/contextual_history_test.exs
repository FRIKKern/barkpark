defmodule Barkpark.Content.Papers.ContextualHistoryTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Papers.ContextualHistory

  @max_bytes 16 * 1024

  test "captures absent and present-empty states and toggles an exact continuation" do
    before = [figure("figure", image("image", "/old.jpg")) |> Map.delete("caption")]
    after_blocks = [put_in(hd(before)["caption"], "")]
    op = patch("figure", "caption", "")

    assert {:ok, continuation} = ContextualHistory.capture(before, after_blocks, [op])

    assert continuation == %{
             "version" => 1,
             "action" => "undo",
             "target" => %{"id" => "figure", "type" => "figure"},
             "field" => "caption",
             "expect" => %{"present" => true, "value" => ""},
             "replace" => %{"present" => false}
           }

    assert :ok = ContextualHistory.validate(continuation)
    assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
    assert redo["action"] == "redo"
    assert redo["expect"] == %{"present" => false}
    assert redo["replace"] == %{"present" => true, "value" => ""}
    assert {:ok, ^after_blocks, ^continuation} = ContextualHistory.apply(before, redo)
  end

  test "distinguishes present nil from an absent field" do
    before = [figure("figure", image("image", "/old.jpg")) |> Map.put("caption", nil)]
    after_blocks = [Map.delete(hd(before), "caption")]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [patch("figure", "caption", nil)])

    assert continuation["expect"] == %{"present" => false}
    assert continuation["replace"] == %{"present" => true, "value" => nil}
    assert {:ok, ^before, _redo} = ContextualHistory.apply(after_blocks, continuation)
  end

  test "undoes a singular Figure image nested in normal containers without rewriting neighbours" do
    target = image("image", "/old.jpg") |> Map.put("alt", "Kept") |> Map.put("opaque", [1, 2])

    before = [
      %{
        "id" => "section",
        "type" => "section",
        "blocks" => [figure("figure", target), paragraph("peer", "Before")],
        "opaque" => %{"section" => true}
      }
    ]

    after_blocks =
      put_in(before, [Access.at(0), "blocks", Access.at(0), "child", "src"], "/new.jpg")

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [patch("image", "src", "/new.jpg")])

    current =
      after_blocks
      |> put_in([Access.at(0), "blocks", Access.at(1), "content"], [
        %{"type" => "text", "value" => "Concurrent peer edit"}
      ])
      |> put_in([Access.at(0), "later"], true)

    original_current = current
    assert {:ok, undone, redo} = ContextualHistory.apply(current, continuation)
    assert current == original_current
    assert get_in(undone, [Access.at(0), "blocks", Access.at(0), "child", "src"]) == "/old.jpg"
    assert get_in(undone, [Access.at(0), "blocks", Access.at(0), "child", "alt"]) == "Kept"
    assert get_in(undone, [Access.at(0), "blocks", Access.at(0), "child", "opaque"]) == [1, 2]

    assert get_in(undone, [Access.at(0), "blocks", Access.at(1), "content"]) == [
             %{"type" => "text", "value" => "Concurrent peer edit"}
           ]

    assert get_in(undone, [Access.at(0), "later"]) == true
    assert {:ok, redone, _undo} = ContextualHistory.apply(undone, redo)
    assert get_in(redone, [Access.at(0), "blocks", Access.at(0), "child", "src"]) == "/new.jpg"
  end

  test "supports exact JSON scalar and opaque field states" do
    before = [figure("figure", image("image", "/old.jpg")) |> Map.put("caption", 42)]
    opaque = [%{"nested" => [true, nil, 3.5]}]
    after_blocks = [Map.put(hd(before), "caption", opaque)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [patch("figure", "caption", opaque)])

    assert continuation["expect"] == %{"present" => true, "value" => opaque}
    assert continuation["replace"] == %{"present" => true, "value" => 42}
    assert {:ok, ^before, _redo} = ContextualHistory.apply(after_blocks, continuation)
  end

  test "paper-links heading fields round-trip while reference and layout edits stay unsupported" do
    before = [
      %{
        "id" => "links",
        "type" => "paper-links",
        "title" => "Before",
        "description" => "Before description",
        "layout" => "chapters",
        "refs" => [%{"slug" => "next", "unknown" => %{"keep" => true}}],
        "unknown" => [1, 2]
      }
    ]

    for {field, value} <- [
          {"title", "  After heading  "},
          {"description", "  After description  "}
        ] do
      after_blocks = [Map.put(hd(before), field, value)]

      assert {:ok, continuation} =
               ContextualHistory.capture(before, after_blocks, [patch("links", field, value)])

      assert continuation["target"] == %{"id" => "links", "type" => "paper-links"}
      assert continuation["field"] == field
      assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
      assert {:ok, ^after_blocks, _undo} = ContextualHistory.apply(before, redo)
    end

    for {field, value} <- [
          {"layout", "timeline"},
          {"refs", [%{"slug" => "other"}]}
        ] do
      after_blocks = [Map.put(hd(before), field, value)]

      assert {:ok, nil} =
               ContextualHistory.capture(before, after_blocks, [patch("links", field, value)])
    end
  end

  test "distinguishes integer and float JSON values exactly" do
    before = [figure("figure", image("image", "/old.jpg")) |> Map.put("caption", 1)]
    after_blocks = [Map.put(hd(before), "caption", 1.0)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [patch("figure", "caption", 1.0)])

    assert continuation["expect"] === %{"present" => true, "value" => 1.0}
    assert continuation["replace"] === %{"present" => true, "value" => 1}
    assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
    assert {:ok, ^after_blocks, _undo} = ContextualHistory.apply(before, redo)
  end

  test "finds and updates singular Figure images through every visible container grammar" do
    for container <- [:section, :expandable, :terminal, :steps, :tabs, :columns] do
      before = wrap(container, figure("figure", image("image", "/old.jpg")))
      after_blocks = wrap(container, figure("figure", image("image", "/new.jpg")))

      assert {:ok, continuation} =
               ContextualHistory.capture(before, after_blocks, [
                 patch("image", "src", "/new.jpg")
               ])

      assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
      assert {:ok, ^after_blocks, _undo} = ContextualHistory.apply(before, redo)
    end
  end

  test "valid unsupported, multi-field, no-op, structural, and malformed captures are not undoable" do
    before = [figure("figure", image("image", "/old.jpg"))]

    assert {:ok, nil} = ContextualHistory.capture(before, before, [])

    assert {:ok, nil} =
             ContextualHistory.capture(before, before, [patch("figure", "caption", "A")])

    assert {:ok, nil} =
             ContextualHistory.capture(before, before, [
               %{
                 "op" => "patch-block",
                 "id" => "figure",
                 "patch" => %{"caption" => "A", "other" => true}
               }
             ])

    unsupported_after = [Map.put(hd(before), "title", "Changed")]

    assert {:ok, nil} =
             ContextualHistory.capture(before, unsupported_after, [
               patch("figure", "title", "Changed")
             ])

    structural_after = before ++ [paragraph("added", "Added")]

    assert {:ok, nil} =
             ContextualHistory.capture(before, structural_after, [patch("figure", "caption", "A")])

    assert {:ok, nil} = ContextualHistory.capture(:bad, before, [patch("figure", "caption", "A")])
    assert {:ok, nil} = ContextualHistory.capture(before, before, :bad)
  end

  test "missing, type-changed, unstable, and duplicate identities never produce history" do
    before = [figure("figure", image("image", "/old.jpg"))]
    changed = [Map.put(hd(before), "caption", "Changed")]
    op = patch("figure", "caption", "Changed")

    assert {:ok, nil} = ContextualHistory.capture([], changed, [op])

    assert {:ok, nil} =
             ContextualHistory.capture(before, [Map.put(hd(changed), "type", "card")], [op])

    assert {:ok, nil} = ContextualHistory.capture([Map.delete(hd(before), "id")], changed, [op])

    duplicate_before = before ++ [paragraph("duplicate", "One"), paragraph("duplicate", "Two")]
    duplicate_after = changed ++ [paragraph("duplicate", "One"), paragraph("duplicate", "Two")]
    assert {:ok, nil} = ContextualHistory.capture(duplicate_before, duplicate_after, [op])
  end

  test "apply fails closed for missing, duplicate, type-changed, and same-field conflicts" do
    before = [figure("figure", image("image", "/old.jpg"))]
    after_blocks = [Map.put(hd(before), "caption", "Changed")]

    {:ok, continuation} =
      ContextualHistory.capture(before, after_blocks, [patch("figure", "caption", "Changed")])

    assert {:error, :block_not_found} = ContextualHistory.apply([], continuation)

    assert {:error, :duplicate_id} =
             ContextualHistory.apply(
               after_blocks ++ [paragraph("duplicate", "A"), paragraph("duplicate", "B")],
               continuation
             )

    assert {:error, :history_conflict} =
             ContextualHistory.apply([Map.put(hd(after_blocks), "type", "card")], continuation)

    assert {:error, :history_conflict} =
             ContextualHistory.apply(
               [Map.put(hd(after_blocks), "caption", "Newer")],
               continuation
             )
  end

  test "validate and apply reject forged or malformed continuations" do
    valid = %{
      "version" => 1,
      "action" => "undo",
      "target" => %{"id" => "figure", "type" => "figure"},
      "field" => "caption",
      "expect" => %{"present" => true, "value" => "After"},
      "replace" => %{"present" => true, "value" => "Before"}
    }

    forged = [
      Map.put(valid, "extra", true),
      Map.put(valid, "version", 2),
      Map.put(valid, "action", "erase"),
      Map.put(valid, "field", "child"),
      put_in(valid, ["target", "type"], "card"),
      put_in(valid, ["target", "extra"], true),
      Map.put(valid, "expect", %{"present" => false, "value" => nil}),
      Map.put(valid, "replace", %{"present" => true, "value" => self()}),
      Map.put(valid, "replace", valid["expect"])
    ]

    for continuation <- forged do
      assert {:error, :invalid_history} = ContextualHistory.validate(continuation)
      assert {:error, :invalid_history} = ContextualHistory.apply([], continuation)
    end

    assert {:error, :invalid_history} = ContextualHistory.validate(nil)
  end

  test "the encoded continuation cap is inclusive and never truncates" do
    before = [figure("figure", image("image", "/old.jpg")) |> Map.delete("caption")]
    {:ok, seed} = capture_caption(before, "x")
    fixed_bytes = byte_size(Jason.encode!(seed)) - 1
    at_limit = String.duplicate("x", @max_bytes - fixed_bytes)

    assert {:ok, continuation} = capture_caption(before, at_limit)
    assert byte_size(Jason.encode!(continuation)) == @max_bytes
    assert :ok = ContextualHistory.validate(continuation)

    assert {:ok, nil} = capture_caption(before, at_limit <> "x")

    assert {:error, :invalid_history} =
             ContextualHistory.validate(
               put_in(continuation, ["expect", "value"], at_limit <> "x")
             )
  end

  test "captures and toggles exact authored paper-link copy without exposing the whole refs array" do
    before_ref = authored_ref(" target ", %{"description" => nil})
    sibling = %{"slug" => "sibling", "unknown" => [1, 1.0, nil]}
    before = [paper_links([before_ref, sibling])]
    after_ref = Map.put(before_ref, "title", "  Authored title  ")
    after_blocks = [paper_links([after_ref, sibling])]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [
               refs_patch("links", [after_ref, sibling])
             ])

    assert continuation == %{
             "version" => 2,
             "action" => "undo",
             "target" => %{
               "id" => "links",
               "type" => "paper-links",
               "ref_index" => 0,
               "ref_slug" => " target "
             },
             "field" => "title",
             "identity" => Map.drop(before_ref, ["title", "description"]),
             "expect" => %{"present" => true, "value" => "  Authored title  "},
             "replace" => %{"present" => false}
           }

    refute inspect(continuation) =~ "sibling"
    assert :ok = ContextualHistory.validate(continuation)
    assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
    assert redo["version"] == 2
    assert redo["action"] == "redo"
    assert {:ok, ^after_blocks, ^continuation} = ContextualHistory.apply(before, redo)
  end

  test "reference copy history preserves interleaved copy and unrelated sibling changes" do
    target = authored_ref("target", %{"title" => "Before", "description" => "Original"})
    sibling = %{"slug" => "sibling", "title" => "Sibling before", "unknown" => true}
    before = [paper_links([target, sibling])]
    saved_target = Map.put(target, "title", "After")
    after_blocks = [paper_links([saved_target, sibling])]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [
               refs_patch("links", [saved_target, sibling])
             ])

    current_target = Map.put(saved_target, "description", "Interleaved description")
    current_sibling = Map.merge(sibling, %{"title" => "Sibling now", "later" => [1, 2]})
    current = [paper_links([current_target, current_sibling]) |> Map.put("later", true)]

    assert {:ok, [undone], redo} = ContextualHistory.apply(current, continuation)
    assert [undone_target, ^current_sibling] = undone["refs"]
    assert undone_target["title"] == "Before"
    assert undone_target["description"] == "Interleaved description"
    assert undone["later"] == true

    assert {:ok, [redone], _undo} = ContextualHistory.apply([undone], redo)
    assert get_in(redone, ["refs", Access.at(0), "title"]) == "After"

    assert get_in(redone, ["refs", Access.at(0), "description"]) ==
             "Interleaved description"
  end

  test "reference copy history distinguishes present nil from an absent description" do
    before_ref = authored_ref("target", %{"description" => nil})
    after_ref = Map.delete(before_ref, "description")
    before = [paper_links([before_ref])]
    after_blocks = [paper_links([after_ref])]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [refs_patch("links", [after_ref])])

    assert continuation["field"] == "description"
    assert continuation["expect"] === %{"present" => false}
    assert continuation["replace"] === %{"present" => true, "value" => nil}
    assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
    assert {:ok, ^after_blocks, _undo} = ContextualHistory.apply(before, redo)
  end

  test "reference history scopes slug uniqueness to the selected target" do
    unrelated = [
      %{"slug" => "duplicate", "unknown" => 1},
      " duplicate ",
      %{"malformed" => true}
    ]

    target = authored_ref("target", %{"title" => "Before"})
    before_refs = unrelated ++ [target]
    saved_target = Map.put(target, "title", "After")
    after_refs = unrelated ++ [saved_target]
    before = [paper_links(before_refs)]
    after_blocks = [paper_links(after_refs)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [refs_patch("links", after_refs)])

    assert continuation["target"]["ref_index"] == 3
    assert continuation["target"]["ref_slug"] == "target"

    current_refs = after_refs ++ [" duplicate ", %{"still" => "malformed"}]
    current = [paper_links(current_refs)]

    assert {:ok, [undone], redo} = ContextualHistory.apply(current, continuation)
    assert Enum.at(undone["refs"], 3) === target
    assert Enum.take(undone["refs"], 3) === unrelated
    assert Enum.drop(undone["refs"], 4) === Enum.drop(current_refs, 4)

    assert {:ok, [redone], _undo} = ContextualHistory.apply([undone], redo)
    assert Enum.at(redone["refs"], 3) === saved_target

    ambiguous_before_refs = before_refs ++ [%{"slug" => " target "}]
    ambiguous_after_refs = after_refs ++ [%{"slug" => " target "}]

    assert {:ok, nil} =
             ContextualHistory.capture(
               [paper_links(ambiguous_before_refs)],
               [paper_links(ambiguous_after_refs)],
               [refs_patch("links", ambiguous_after_refs)]
             )

    duplicate_target = [paper_links(current_refs ++ [%{"slug" => " target "}])]
    assert {:error, :history_conflict} = ContextualHistory.apply(duplicate_target, continuation)
  end

  test "reference capture rejects ambiguous ownership and any change beyond one copy field" do
    target = authored_ref("target", %{"title" => "Before", "description" => "Description"})
    sibling = %{"slug" => "sibling"}
    before = [paper_links([target, sibling])]
    after_title = Map.put(target, "title", "After")

    unsupported = [
      [paper_links([Map.put(after_title, "prefer_authored_copy", false), sibling])],
      [paper_links([Map.put(after_title, "unknown", "changed"), sibling])],
      [paper_links([Map.put(after_title, "description", "Also changed"), sibling])],
      [paper_links([sibling, after_title])],
      [paper_links([after_title, sibling]) |> Map.put("layout", "timeline")],
      [paper_links([after_title, %{"slug" => " target "}])],
      [paper_links([after_title, " target "])],
      [paper_links([Map.delete(after_title, "slug"), sibling])]
    ]

    for after_blocks <- unsupported do
      assert {:ok, nil} =
               ContextualHistory.capture(before, after_blocks, [
                 refs_patch("links", hd(after_blocks)["refs"])
               ])
    end

    assert {:ok, nil} =
             ContextualHistory.capture(before, before, [refs_patch("links", hd(before)["refs"])])

    assert {:ok, nil} =
             ContextualHistory.capture(before, [paper_links([after_title, sibling])], [
               patch("links", "refs", [after_title, sibling]) |> put_in(["patch", "extra"], true)
             ])
  end

  test "reference apply fails closed after reorder, ownership, metadata, selected-field, or slug ambiguity changes" do
    target = authored_ref("target", %{"title" => "Before", "description" => "Description"})
    sibling = %{"slug" => "sibling"}
    before = [paper_links([target, sibling])]
    saved_target = Map.put(target, "title", "After")
    after_blocks = [paper_links([saved_target, sibling])]

    {:ok, continuation} =
      ContextualHistory.capture(before, after_blocks, [
        refs_patch("links", [saved_target, sibling])
      ])

    conflicts = [
      [paper_links([sibling, saved_target])],
      [paper_links([Map.put(saved_target, "slug", "other"), sibling])],
      [paper_links([Map.put(saved_target, "unknown", "changed"), sibling])],
      [paper_links([Map.put(saved_target, "prefer_authored_copy", false), sibling])],
      [paper_links([Map.put(saved_target, "title", "Newer"), sibling])],
      [paper_links([saved_target, %{"slug" => " target "}])]
    ]

    for current <- conflicts do
      assert {:error, :history_conflict} = ContextualHistory.apply(current, continuation)
    end

    canonically_equal_but_raw_changed =
      [paper_links([Map.put(saved_target, "slug", " target "), sibling])]

    assert {:error, :history_conflict} =
             ContextualHistory.apply(canonically_equal_but_raw_changed, continuation)
  end

  test "validates the private v2 shape strictly and rejects forged identity or target fields" do
    identity = %{
      "slug" => "target",
      "prefer_authored_copy" => true,
      "unknown" => %{"keep" => true}
    }

    valid = %{
      "version" => 2,
      "action" => "undo",
      "target" => %{
        "id" => "links",
        "type" => "paper-links",
        "ref_index" => 0,
        "ref_slug" => "target"
      },
      "field" => "description",
      "identity" => identity,
      "expect" => %{"present" => true, "value" => nil},
      "replace" => %{"present" => false}
    }

    assert :ok = ContextualHistory.validate(valid)

    for forged <- [
          Map.put(valid, "extra", true),
          Map.put(valid, "field", "refs"),
          Map.put(valid, "identity", Map.put(identity, "title", "leak")),
          Map.put(valid, "identity", Map.put(identity, "description", "leak")),
          Map.put(valid, "identity", Map.put(identity, "prefer_authored_copy", false)),
          put_in(valid, ["target", "type"], "figure"),
          put_in(valid, ["target", "ref_index"], -1),
          put_in(valid, ["target", "ref_slug"], ""),
          put_in(valid, ["target", "extra"], true)
        ] do
      assert {:error, :invalid_history} = ContextualHistory.validate(forged)
      assert {:error, :invalid_history} = ContextualHistory.apply([], forged)
    end
  end

  test "the v2 encoded continuation uses the existing inclusive 16 KiB cap" do
    target = authored_ref("target", %{})
    before = [paper_links([target])]
    after_target = Map.put(target, "title", "x")

    {:ok, seed} =
      ContextualHistory.capture(before, [paper_links([after_target])], [
        refs_patch("links", [after_target])
      ])

    fixed_bytes = byte_size(Jason.encode!(seed)) - 1
    at_limit = String.duplicate("x", @max_bytes - fixed_bytes)
    limited_target = Map.put(target, "title", at_limit)

    assert {:ok, continuation} =
             ContextualHistory.capture(before, [paper_links([limited_target])], [
               refs_patch("links", [limited_target])
             ])

    assert byte_size(Jason.encode!(continuation)) == @max_bytes

    assert {:ok, nil} =
             ContextualHistory.capture(
               before,
               [paper_links([Map.put(target, "title", at_limit <> "x")])],
               [
                 refs_patch("links", [Map.put(target, "title", at_limit <> "x")])
               ]
             )
  end

  defp capture_caption(before, caption) do
    after_blocks = [Map.put(hd(before), "caption", caption)]
    ContextualHistory.capture(before, after_blocks, [patch("figure", "caption", caption)])
  end

  defp patch(id, field, value),
    do: %{"op" => "patch-block", "id" => id, "patch" => %{field => value}}

  defp refs_patch(id, refs), do: patch(id, "refs", refs)

  defp paper_links(refs),
    do: %{
      "id" => "links",
      "type" => "paper-links",
      "layout" => "chapters",
      "refs" => refs,
      "unknown" => %{"keep" => true}
    }

  defp authored_ref(slug, extra) do
    Map.merge(
      %{
        "slug" => slug,
        "prefer_authored_copy" => true,
        "unknown" => %{"keep" => [true, nil, 1, 1.0]}
      },
      extra
    )
  end

  defp figure(id, child),
    do: %{"id" => id, "type" => "figure", "caption" => "Before", "child" => child}

  defp image(id, src), do: %{"id" => id, "type" => "image", "src" => src}

  defp paragraph(id, value),
    do: %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => value}]
    }

  defp wrap(:section, block),
    do: [%{"id" => "section", "type" => "section", "blocks" => [block]}]

  defp wrap(:expandable, block),
    do: [%{"id" => "expandable", "type" => "expandable", "children" => [block]}]

  defp wrap(:terminal, block),
    do: [%{"id" => "terminal", "type" => "terminal", "children" => [block]}]

  defp wrap(:steps, block),
    do: [
      %{
        "id" => "steps",
        "type" => "steps",
        "steps" => [%{"id" => "step", "children" => [block]}]
      }
    ]

  defp wrap(:tabs, block),
    do: [
      %{"id" => "tabs", "type" => "tabs", "tabs" => [%{"id" => "tab", "blocks" => [block]}]}
    ]

  defp wrap(:columns, block),
    do: [%{"id" => "columns", "type" => "columns", "columns" => [[block]]}]
end
