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

  test "card action label history preserves exact scalar states" do
    states = [
      {%{"present" => false}, %{"present" => true, "value" => nil}},
      {%{"present" => true, "value" => nil}, %{"present" => true, "value" => ""}},
      {%{"present" => true, "value" => ""}, %{"present" => true, "value" => "   "}},
      {%{"present" => true, "value" => "   "}, %{"present" => true, "value" => "Read next"}}
    ]

    for {before_state, after_state} <- states do
      before_action = put_state(card_action(), "label", before_state)
      after_action = put_state(card_action(), "label", after_state)
      before = [card(before_action)]
      after_blocks = [card(after_action)]

      assert {:ok, continuation} =
               ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

      assert continuation == %{
               "version" => 3,
               "action" => "undo",
               "target" => %{"id" => "card", "type" => "card"},
               "field" => "action.label",
               "expect" => after_state,
               "replace" => before_state
             }

      assert :ok = ContextualHistory.validate(continuation)
      assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
      assert redo["action"] == "redo"
      assert {:ok, ^after_blocks, ^continuation} = ContextualHistory.apply(before, redo)
    end
  end

  test "card action label history preserves concurrent Card and action fields" do
    before_action =
      card_action()
      |> Map.put("label", "Before")
      |> Map.put("opaque", %{"keep" => [true, nil, 1, 1.0]})

    before = [card(before_action)]
    saved_action = Map.put(before_action, "label", "After")
    after_blocks = [card(saved_action)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

    concurrent_action =
      saved_action
      |> Map.put("href", "/concurrent")
      |> Map.put("priority", "secondary")
      |> Map.put("later", %{"keep" => true})

    current =
      card(concurrent_action)
      |> put_in(["slots", "title"], [%{"type" => "heading", "text" => "Concurrent"}])
      |> put_in(["slots", "media"], [%{"type" => "image", "src" => "/new.png"}])
      |> Map.put("outside", [1, 2])
      |> then(&[&1])

    assert {:ok, [undone], redo} = ContextualHistory.apply(current, continuation)
    [undone_action] = get_in(undone, ["slots", "action"])
    assert undone_action == Map.put(concurrent_action, "label", "Before")
    assert get_in(undone, ["slots", "title"]) == [%{"type" => "heading", "text" => "Concurrent"}]
    assert get_in(undone, ["slots", "media"]) == [%{"type" => "image", "src" => "/new.png"}]
    assert undone["outside"] == [1, 2]

    assert {:ok, [redone], _undo} = ContextualHistory.apply([undone], redo)
    assert get_in(redone, ["slots", "action", Access.at(0), "label"]) == "After"
    assert get_in(redone, ["slots", "action", Access.at(0), "href"]) == "/concurrent"
  end

  test "card action capture rejects broad, structural, and malformed changes" do
    before_action = Map.put(card_action(), "label", "Before")
    before = [card(before_action)]
    after_action = Map.put(before_action, "label", "After")
    valid_after = [card(after_action)]

    unsupported = [
      {[card(Map.put(after_action, "href", "/changed"))], slots_patch(valid_after)},
      {[card(after_action), card(Map.put(after_action, "label", "Other"), "other")],
       slots_patch(valid_after)},
      {[%{"id" => "card", "type" => "card", "slots" => %{"action" => [after_action]}}],
       slots_patch(valid_after)},
      {[card(nil)], slots_patch([card(nil)])},
      {[card([after_action, after_action])], slots_patch([card([after_action, after_action])])},
      {[card(Map.put(after_action, "type", "button"))], slots_patch(valid_after)},
      {[card(Map.put(after_action, "label", 42))], slots_patch(valid_after)},
      {[card(Map.put(after_action, "label", [%{"type" => "text", "value" => "After"}]))],
       slots_patch(valid_after)},
      {[card(Map.put(after_action, "href", %{"rich" => true}))], slots_patch(valid_after)},
      {[card(Map.put(after_action, "priority", []))], slots_patch(valid_after)}
    ]

    for {after_blocks, op} <- unsupported do
      assert {:ok, nil} = ContextualHistory.capture(before, after_blocks, [op])
    end

    without_action = [put_in(hd(before), ["slots", "action"], [])]

    assert {:ok, nil} =
             ContextualHistory.capture(without_action, valid_after, [slots_patch(valid_after)])

    assert {:ok, nil} =
             ContextualHistory.capture(before, without_action, [slots_patch(without_action)])

    duplicate_before = before ++ [card(before_action)]
    duplicate_after = valid_after ++ [card(before_action)]

    assert {:ok, nil} =
             ContextualHistory.capture(duplicate_before, duplicate_after, [
               slots_patch(valid_after)
             ])

    assert {:ok, nil} =
             ContextualHistory.capture(before, valid_after, [
               put_in(slots_patch(valid_after), ["patch", "extra"], true)
             ])
  end

  test "card action apply and validation fail closed" do
    before_action = Map.put(card_action(), "label", "Before")
    before = [card(before_action)]
    after_action = Map.put(before_action, "label", "After")
    after_blocks = [card(after_action)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

    for current <- [
          [card(nil)],
          [card([after_action, after_action])],
          [card(Map.put(after_action, "type", "button"))],
          [card(Map.put(after_action, "label", "Newer"))],
          [card(Map.put(after_action, "label", 42))],
          [card(Map.put(after_action, "label", [%{"type" => "text", "value" => "Newer"}]))],
          [card(Map.put(after_action, "href", %{"rich" => true}))],
          [card(Map.put(after_action, "priority", []))]
        ] do
      assert {:error, :history_conflict} = ContextualHistory.apply(current, continuation)
    end

    for invalid <- [
          Map.put(continuation, "version", 3.0),
          Map.put(continuation, "extra", true),
          Map.put(continuation, "field", "action.href"),
          put_in(continuation, ["target", "type"], "paper-links"),
          Map.put(continuation, "expect", %{"present" => true, "value" => 42}),
          Map.put(continuation, "replace", continuation["expect"])
        ] do
      assert {:error, :invalid_history} = ContextualHistory.validate(invalid)
      assert {:error, :invalid_history} = ContextualHistory.apply(after_blocks, invalid)
    end

    oversized = put_in(continuation, ["replace", "value"], String.duplicate("x", @max_bytes))
    assert {:error, :invalid_history} = ContextualHistory.validate(oversized)
  end

  test "card action continuation uses the inclusive encoded-size cap" do
    before_action = Map.put(card_action(), "label", "Before")
    before = [card(before_action)]
    seed_after = [card(Map.put(before_action, "label", "x"))]

    assert {:ok, seed} =
             ContextualHistory.capture(before, seed_after, [slots_patch(seed_after)])

    fixed_bytes = byte_size(Jason.encode!(seed)) - 1
    at_limit = String.duplicate("x", @max_bytes - fixed_bytes)
    limited_after = [card(Map.put(before_action, "label", at_limit))]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, limited_after, [slots_patch(limited_after)])

    assert byte_size(Jason.encode!(continuation)) == @max_bytes
    assert :ok = ContextualHistory.validate(continuation)

    over_limit = [card(Map.put(before_action, "label", at_limit <> "x"))]

    assert {:ok, nil} =
             ContextualHistory.capture(before, over_limit, [slots_patch(over_limit)])
  end

  test "card media source history preserves exact carrier type and source states" do
    type_states = [
      %{"present" => false},
      %{"present" => true, "value" => nil},
      %{"present" => true, "value" => "image"}
    ]

    source_changes = [
      {%{"present" => false}, %{"present" => true, "value" => nil}},
      {%{"present" => true, "value" => nil}, %{"present" => true, "value" => ""}},
      {%{"present" => true, "value" => ""}, %{"present" => true, "value" => "   "}},
      {%{"present" => true, "value" => "   "}, %{"present" => true, "value" => "/after.png"}}
    ]

    for type_state <- type_states, {before_state, after_state} <- source_changes do
      before_media =
        card_media()
        |> put_state("type", type_state)
        |> put_state("src", before_state)

      after_media = put_state(before_media, "src", after_state)
      before = [card_with_media(before_media)]
      after_blocks = [card_with_media(after_media)]

      assert {:ok, continuation} =
               ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

      assert continuation == %{
               "version" => 4,
               "action" => "undo",
               "target" => %{"id" => "card", "type" => "card"},
               "field" => "media.src",
               "identity" => %{"type" => type_state},
               "expect" => after_state,
               "replace" => before_state
             }

      assert :ok = ContextualHistory.validate(continuation)
      assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
      assert redo["action"] == "redo"
      assert {:ok, ^after_blocks, ^continuation} = ContextualHistory.apply(before, redo)
    end
  end

  test "card media source history preserves concurrent carrier metadata and Card fields" do
    before_media =
      card_media()
      |> Map.put("src", "/before.png")
      |> Map.put("alt", "Before alt")
      |> Map.put("width", 640)
      |> Map.put("height", 320)
      |> Map.put("opaque", %{"keep" => [true, nil, 1, 1.0]})

    saved_media = Map.put(before_media, "src", "/after.png")
    before = [card_with_media(before_media)]
    after_blocks = [card_with_media(saved_media)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

    concurrent_media =
      saved_media
      |> Map.put("alt", "Concurrent alt")
      |> Map.put("width", 1280)
      |> Map.put("height", nil)
      |> Map.put("id", "concurrent-owner")
      |> Map.put("opaque", %{"later" => [false, %{}]})

    current =
      card_with_media(concurrent_media)
      |> put_in(["slots", "title"], [%{"type" => "heading", "text" => "Concurrent title"}])
      |> put_in(["slots", "action", Access.at(0), "href"], "/concurrent")
      |> Map.put("tone", "strong")
      |> Map.put("outside", %{"keep" => true})
      |> then(&[&1])

    assert {:ok, [undone], redo} = ContextualHistory.apply(current, continuation)
    assert get_in(undone, ["slots", "media"]) == [Map.put(concurrent_media, "src", "/before.png")]

    assert get_in(undone, ["slots", "title"]) == [
             %{"type" => "heading", "text" => "Concurrent title"}
           ]

    assert get_in(undone, ["slots", "action", Access.at(0), "href"]) == "/concurrent"
    assert undone["tone"] == "strong"
    assert undone["outside"] == %{"keep" => true}

    assert {:ok, [redone], _undo} = ContextualHistory.apply([undone], redo)
    assert get_in(redone, ["slots", "media"]) == [concurrent_media]
  end

  test "card media source capture rejects structural, broad, and malformed changes" do
    before_media = Map.put(card_media(), "src", "/before.png")
    after_media = Map.put(before_media, "src", "/after.png")
    before = [card_with_media(before_media)]
    valid_after = [card_with_media(after_media)]

    unsupported = [
      [card_with_media(Map.put(after_media, "alt", "Changed too"))],
      [card_with_media(Map.put(after_media, "type", nil))],
      [card_with_media([after_media, after_media])],
      [card_with_media(Map.put(after_media, "src", 42))],
      [card_with_media(Map.put(after_media, "alt", %{}))],
      [card_with_media(Map.put(after_media, "type", "video"))],
      [card_with_media(nil)],
      [card_with_media([])]
    ]

    for after_blocks <- unsupported do
      assert {:ok, nil} =
               ContextualHistory.capture(before, after_blocks, [slots_patch(valid_after)])
    end

    without_media = [card_with_media(:absent)]

    assert {:ok, nil} =
             ContextualHistory.capture(without_media, valid_after, [slots_patch(valid_after)])

    assert {:ok, nil} =
             ContextualHistory.capture(before, without_media, [slots_patch(without_media)])

    duplicate_before = before ++ [card_with_media(before_media)]
    duplicate_after = valid_after ++ [card_with_media(before_media)]

    assert {:ok, nil} =
             ContextualHistory.capture(duplicate_before, duplicate_after, [
               slots_patch(valid_after)
             ])

    assert {:ok, nil} =
             ContextualHistory.capture(before, valid_after, [
               put_in(slots_patch(valid_after), ["patch", "extra"], true)
             ])
  end

  test "card media source apply and validation fail closed" do
    before_media = Map.put(card_media(), "src", "/before.png")
    after_media = Map.put(before_media, "src", "/after.png")
    before = [card_with_media(before_media)]
    after_blocks = [card_with_media(after_media)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

    for current <- [
          [card_with_media(Map.put(after_media, "src", "/newer.png"))],
          [card_with_media(Map.delete(after_media, "type"))],
          [card_with_media(Map.put(after_media, "type", nil))],
          [card_with_media(Map.put(after_media, "type", "video"))],
          [card_with_media(Map.put(after_media, "src", 42))],
          [card_with_media(Map.put(after_media, "alt", []))],
          [card_with_media([after_media, after_media])],
          [card_with_media(nil)],
          [card_with_media([])]
        ] do
      assert {:error, :history_conflict} = ContextualHistory.apply(current, continuation)
    end

    duplicate = after_blocks ++ after_blocks
    assert {:error, :duplicate_id} = ContextualHistory.apply(duplicate, continuation)

    for invalid <- [
          Map.put(continuation, "version", 4.0),
          Map.put(continuation, "extra", true),
          Map.put(continuation, "field", "media.alt"),
          Map.delete(continuation, "identity"),
          put_in(continuation, ["identity", "extra"], true),
          put_in(continuation, ["identity", "type"], %{"present" => true, "value" => "video"}),
          put_in(continuation, ["target", "type"], "image"),
          Map.put(continuation, "expect", %{"present" => true, "value" => 42}),
          Map.put(continuation, "replace", continuation["expect"])
        ] do
      assert {:error, :invalid_history} = ContextualHistory.validate(invalid)
      assert {:error, :invalid_history} = ContextualHistory.apply(after_blocks, invalid)
    end
  end

  test "card media source continuation uses the inclusive encoded-size cap" do
    before_media = Map.put(card_media(), "src", "/before.png")
    before = [card_with_media(before_media)]
    seed_after = [card_with_media(Map.put(before_media, "src", "x"))]

    assert {:ok, seed} =
             ContextualHistory.capture(before, seed_after, [slots_patch(seed_after)])

    fixed_bytes = byte_size(Jason.encode!(seed)) - 1
    at_limit = String.duplicate("x", @max_bytes - fixed_bytes)
    limited_after = [card_with_media(Map.put(before_media, "src", at_limit))]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, limited_after, [slots_patch(limited_after)])

    assert byte_size(Jason.encode!(continuation)) == @max_bytes
    assert :ok = ContextualHistory.validate(continuation)

    over_limit = [card_with_media(Map.put(before_media, "src", at_limit <> "x"))]

    assert {:ok, nil} =
             ContextualHistory.capture(before, over_limit, [slots_patch(over_limit)])
  end

  test "card title text history preserves exact text and content states" do
    content_states = [
      %{"present" => false},
      %{"present" => true, "value" => nil},
      %{"present" => true, "value" => []}
    ]

    text_changes = [
      {"Before", ""},
      {"", "   "},
      {"   ", "After"}
    ]

    for content_state <- content_states,
        level <- [:absent, nil, 1, 2, 3, "1", "2", "3"],
        {before_text, after_text} <- text_changes do
      before_title = card_title(before_text, content_state, level)
      after_title = Map.put(before_title, "text", after_text)
      before = [card_with_title(before_title)]
      after_blocks = [card_with_title(after_title)]

      assert {:ok, continuation} =
               ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

      assert continuation == %{
               "version" => 5,
               "action" => "undo",
               "target" => %{"id" => "card", "type" => "card"},
               "field" => "title.text",
               "identity" => %{
                 "type" => %{"present" => true, "value" => "heading"},
                 "content" => content_state
               },
               "expect" => %{"present" => true, "value" => after_text},
               "replace" => %{"present" => true, "value" => before_text}
             }

      assert :ok = ContextualHistory.validate(continuation)
      assert {:ok, ^before, redo} = ContextualHistory.apply(after_blocks, continuation)
      assert redo["action"] == "redo"
      assert {:ok, ^after_blocks, ^continuation} = ContextualHistory.apply(before, redo)
    end
  end

  test "card title text history preserves concurrent admissible title and Card metadata" do
    before_title =
      card_title("Before", %{"present" => true, "value" => []}, 2)
      |> Map.put("id", "title-owner")
      |> Map.put("opaque", %{"keep" => [true, nil, 1, 1.0]})

    saved_title = Map.put(before_title, "text", "After")
    before = [card_with_title(before_title)]
    after_blocks = [card_with_title(saved_title)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

    concurrent_title =
      saved_title
      |> Map.put("level", "3")
      |> Map.put("id", "concurrent-title-owner")
      |> Map.put("opaque", %{"later" => [false, %{}]})

    current =
      card_with_title(concurrent_title)
      |> put_in(["slots", "media", Access.at(0), "src"], "/concurrent.png")
      |> put_in(["slots", "action", Access.at(0), "href"], "/concurrent")
      |> Map.put("tone", "warn")
      |> Map.put("outside", %{"keep" => true})
      |> then(&[&1])

    assert {:ok, [undone], redo} = ContextualHistory.apply(current, continuation)

    assert get_in(undone, ["slots", "title"]) == [
             Map.put(concurrent_title, "text", "Before")
           ]

    assert get_in(undone, ["slots", "media", Access.at(0), "src"]) == "/concurrent.png"
    assert get_in(undone, ["slots", "action", Access.at(0), "href"]) == "/concurrent"
    assert undone["tone"] == "warn"
    assert undone["outside"] == %{"keep" => true}

    assert {:ok, [redone], _undo} = ContextualHistory.apply([undone], redo)
    assert get_in(redone, ["slots", "title"]) == [concurrent_title]
  end

  test "card title capture rejects broad, structural, and malformed changes" do
    before_title = card_title("Before")
    after_title = Map.put(before_title, "text", "After")
    before = [card_with_title(before_title)]
    valid_after = [card_with_title(after_title)]

    unsupported = [
      [card_with_title(Map.put(after_title, "level", 3))],
      [card_with_title(Map.put(after_title, "content", [%{"type" => "text"}]))],
      [card_with_title(Map.delete(after_title, "type"))],
      [card_with_title(Map.put(after_title, "type", nil))],
      [card_with_title(Map.put(after_title, "type", "paragraph"))],
      [card_with_title(Map.delete(after_title, "text"))],
      [card_with_title(Map.put(after_title, "text", nil))],
      [card_with_title(Map.put(after_title, "text", 42))],
      [card_with_title(Map.put(after_title, "level", 4))],
      [card_with_title(Map.put(after_title, "level", "4"))],
      [card_with_title([after_title, after_title])],
      [card_with_title(nil)],
      [card_with_title([])]
    ]

    for after_blocks <- unsupported do
      assert {:ok, nil} =
               ContextualHistory.capture(before, after_blocks, [slots_patch(valid_after)])
    end

    assert {:ok, nil} =
             ContextualHistory.capture(before, before, [slots_patch(before)])

    without_title = [card_with_title(:absent)]

    assert {:ok, nil} =
             ContextualHistory.capture(without_title, valid_after, [slots_patch(valid_after)])

    assert {:ok, nil} =
             ContextualHistory.capture(before, without_title, [slots_patch(without_title)])

    duplicate_before = before ++ [card_with_title(before_title)]
    duplicate_after = valid_after ++ [card_with_title(before_title)]

    assert {:ok, nil} =
             ContextualHistory.capture(duplicate_before, duplicate_after, [
               slots_patch(valid_after)
             ])

    assert {:ok, nil} =
             ContextualHistory.capture(before, valid_after, [
               put_in(slots_patch(valid_after), ["patch", "extra"], true)
             ])
  end

  test "card title apply and validation fail closed" do
    before_title = card_title("Before")
    after_title = Map.put(before_title, "text", "After")
    before = [card_with_title(before_title)]
    after_blocks = [card_with_title(after_title)]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, after_blocks, [slots_patch(after_blocks)])

    for current <- [
          [card_with_title(Map.put(after_title, "text", "Newer"))],
          [card_with_title(Map.put(after_title, "content", nil))],
          [card_with_title(Map.put(after_title, "content", []))],
          [card_with_title(Map.delete(after_title, "type"))],
          [card_with_title(Map.put(after_title, "type", nil))],
          [card_with_title(Map.put(after_title, "type", "paragraph"))],
          [card_with_title(Map.delete(after_title, "text"))],
          [card_with_title(Map.put(after_title, "text", nil))],
          [card_with_title(Map.put(after_title, "level", 4))],
          [card_with_title([after_title, after_title])],
          [card_with_title(nil)],
          [card_with_title([])]
        ] do
      assert {:error, :history_conflict} = ContextualHistory.apply(current, continuation)
    end

    duplicate = after_blocks ++ after_blocks
    assert {:error, :duplicate_id} = ContextualHistory.apply(duplicate, continuation)

    for invalid <- [
          Map.put(continuation, "version", 5.0),
          Map.put(continuation, "extra", true),
          Map.put(continuation, "field", "title.level"),
          Map.delete(continuation, "identity"),
          put_in(continuation, ["identity", "extra"], true),
          put_in(continuation, ["identity", "type"], %{"present" => false}),
          put_in(continuation, ["identity", "content"], %{"present" => true, "value" => %{}}),
          put_in(continuation, ["target", "type"], "heading"),
          Map.put(continuation, "expect", %{"present" => false}),
          Map.put(continuation, "expect", %{"present" => true, "value" => nil}),
          Map.put(continuation, "replace", continuation["expect"])
        ] do
      assert {:error, :invalid_history} = ContextualHistory.validate(invalid)
      assert {:error, :invalid_history} = ContextualHistory.apply(after_blocks, invalid)
    end

    oversized = put_in(continuation, ["replace", "value"], String.duplicate("x", @max_bytes))
    assert {:error, :invalid_history} = ContextualHistory.validate(oversized)
  end

  test "card title continuation uses the inclusive encoded-size cap" do
    before_title = card_title("Before")
    before = [card_with_title(before_title)]
    seed_after = [card_with_title(Map.put(before_title, "text", "x"))]

    assert {:ok, seed} =
             ContextualHistory.capture(before, seed_after, [slots_patch(seed_after)])

    fixed_bytes = byte_size(Jason.encode!(seed)) - 1
    at_limit = String.duplicate("x", @max_bytes - fixed_bytes)
    limited_after = [card_with_title(Map.put(before_title, "text", at_limit))]

    assert {:ok, continuation} =
             ContextualHistory.capture(before, limited_after, [slots_patch(limited_after)])

    assert byte_size(Jason.encode!(continuation)) == @max_bytes
    assert :ok = ContextualHistory.validate(continuation)

    over_limit = [card_with_title(Map.put(before_title, "text", at_limit <> "x"))]

    assert {:ok, nil} =
             ContextualHistory.capture(before, over_limit, [slots_patch(over_limit)])
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

  defp card(action, id \\ "card") do
    action_slot = if is_list(action), do: action, else: [action]

    %{
      "id" => id,
      "type" => "card",
      "tone" => "calm",
      "slots" => %{
        "title" => [%{"type" => "heading", "text" => "Title"}],
        "body" => [%{"type" => "paragraph", "content" => []}],
        "media" => [%{"type" => "image", "src" => "/image.png", "unknown" => true}],
        "action" => action_slot,
        "future" => %{"keep" => true}
      },
      "unknown" => [1, 2]
    }
  end

  defp card_action do
    %{
      "type" => "action",
      "href" => "/read",
      "priority" => "primary",
      "unknown" => %{"keep" => true}
    }
  end

  defp card_media do
    %{
      "type" => "image",
      "alt" => "Kept",
      "width" => 640,
      "unknown" => %{"keep" => true}
    }
  end

  defp card_with_media(media, id \\ "card") do
    action = card_action() |> Map.put("label", "Read")
    block = card(action, id)

    slots =
      case media do
        :absent -> Map.delete(block["slots"], "media")
        value when is_list(value) -> Map.put(block["slots"], "media", value)
        value -> Map.put(block["slots"], "media", [value])
      end

    Map.put(block, "slots", slots)
  end

  defp card_title(text, content_state \\ %{"present" => false}, level \\ :absent) do
    %{"type" => "heading", "text" => text, "unknown" => %{"keep" => true}}
    |> put_state("content", content_state)
    |> then(fn title -> if level === :absent, do: title, else: Map.put(title, "level", level) end)
  end

  defp card_with_title(title, id \\ "card") do
    action = card_action() |> Map.put("label", "Read")
    block = card(action, id)

    slots =
      case title do
        :absent -> Map.delete(block["slots"], "title")
        value when is_list(value) -> Map.put(block["slots"], "title", value)
        value -> Map.put(block["slots"], "title", [value])
      end

    Map.put(block, "slots", slots)
  end

  defp slots_patch([block]), do: patch(block["id"], "slots", block["slots"])

  defp put_state(map, field, %{"present" => false}), do: Map.delete(map, field)

  defp put_state(map, field, %{"present" => true, "value" => value}),
    do: Map.put(map, field, value)

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
