defmodule Barkpark.PortableDoc.Render.HeadingAliasDriftTest do
  # Pure compose — no DB, no fixtures.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose

  # ── the h1/h2/h3 + ordered-list live-drift guard (charter D57) ───────────────
  #
  # Before this slice these four spellings matched NO `compose_block/2` clause,
  # so 20 blocks in live production papers composed to `unknown_block_node/1`
  # and drew "Unsupported block" on the View and Email surfaces — the same bug
  # class as the bulletList alias family that was fixed for 77 blocks.
  #
  # The inputs are the REAL live blocks, copied out of the production corpus
  # (`ctx-compression-wave-2026-07-24`, censused 2026-07-27 across all 553
  # published papers). Synthetic inputs would have missed the load-bearing
  # detail: SIX of the 18 drifted headings (1 h2 + all 5 h3s) carry NO `"level"`
  # key, so a clause that borrowed the heading body without forcing the level
  # from the TYPE would compose an `h3` into a level-2 `PdHeading`.
  #
  # Coverage note, honestly stated: the four PRE-EXISTING alias spellings
  # (bulletList / bullet_list / bulleted-list / bulleted_list / numbered_list /
  # quote) have no Elixir test of their own anywhere in api/test — this file
  # covers only the D57 family it ships. That gap is real and is not this
  # slice's to close.

  describe "h1/h2/h3 alias" do
    test "each live drifted heading composes to a real PdHeading, never the unknown box" do
      for {block, level} <- [
            {%{
               "id" => "w1-002",
               "level" => 1,
               "type" => "h1",
               "text" => "The manifest goes brief"
             }, 1},
            {%{"id" => "w1-010", "level" => 2, "type" => "h2", "text" => "The wish (verbatim)"},
             2},
            # The two level-LESS live shapes — the whole point of type authority.
            {%{"id" => "w1-d00", "type" => "h2", "text" => "DEBRIEF — wave closed"}, 2},
            {%{"id" => "w1-d02", "type" => "h3", "text" => "Shipped"}, 3}
          ] do
        composed = Compose.compose_block(block, :article)

        assert match?(%{"kind" => "PdHeading", "level" => ^level, "children" => [_]}, composed),
               "#{block["type"]} (level key #{inspect(block["level"])}) composed to #{inspect(composed)}"

        %{"children" => [text]} = composed

        assert text == block["text"]
      end
    end

    test "a contradicting stored level loses to the type" do
      assert %{"kind" => "PdHeading", "level" => 3} =
               Compose.compose_block(%{"type" => "h3", "level" => 1, "text" => "x"}, :article)
    end

    test "the aliases are byte-identical to the canonical heading at that level" do
      for {type, level} <- [{"h1", 1}, {"h2", 2}, {"h3", 3}] do
        aliased = Compose.compose_block(%{"type" => type, "text" => "same words"}, :article)

        canonical =
          Compose.compose_block(
            %{"type" => "heading", "level" => level, "text" => "same words"},
            :article
          )

        assert aliased == canonical
      end

      # The mutation guard: levels must actually differ in the composed node, or
      # every assertion above would pass on a renderer that ignored the level.
      assert Compose.compose_block(%{"type" => "h2", "text" => "x"}, :article) !=
               Compose.compose_block(%{"type" => "h3", "text" => "x"}, :article)
    end

    test "the content[] shape routes through the same content||text law" do
      assert %{"kind" => "PdHeading", "level" => 2, "children" => ["inline shape"]} =
               Compose.compose_block(
                 %{"type" => "h2", "content" => [%{"type" => "text", "value" => "inline shape"}]},
                 :article
               )
    end

    test "h4 is deliberately NOT aliased — the live corpus has none" do
      # Recorded ceiling, not an oversight: the census found zero h4/h5/h6 blocks,
      # and PdHeading only models levels 1-3. An h4 keeps degrading honestly.
      assert %{"kind" => "_raw", "html" => html} =
               Compose.compose_block(%{"type" => "h4", "text" => "x"}, :article)

      assert html =~ "Unsupported block: h4"
    end
  end

  describe "ordered-list alias" do
    test "composes to an ORDERED PdList, identically to the canonical list" do
      items = [
        [%{"type" => "text", "value" => "first"}],
        [%{"type" => "text", "value" => "second"}]
      ]

      aliased = Compose.compose_block(%{"type" => "ordered-list", "items" => items}, :article)

      canonical =
        Compose.compose_block(
          %{"type" => "list", "ordered" => true, "items" => items},
          :article
        )

      assert %{"kind" => "PdList", "ordered" => true, "children" => children} = aliased
      assert length(children) == 2
      assert aliased == canonical

      # The unordered canonical sibling is untouched — this alias adds ordering,
      # it does not make every list ordered.
      assert %{"ordered" => false} =
               Compose.compose_block(%{"type" => "list", "items" => items}, :article)
    end

    test "map-shaped items keep the ordering and the item COUNT" do
      # The live blocks persist items as maps with their own `content[]`. Those
      # compose to EMPTY PdText today — the pre-existing list-item normalization
      # defect this surface shares with the Go TUI (charter D38,
      # task-993d136b0fbf2fd1), reproduced identically by the canonical `list`.
      # This alias is therefore pinned on what it owns: ordering and arity.
      items = [
        %{"content" => [%{"type" => "text", "value" => "Count a criterion as met"}]},
        %{"content" => [%{"type" => "text", "value" => "Sort by unmet criteria"}]}
      ]

      assert %{"kind" => "PdList", "ordered" => true, "children" => children} =
               Compose.compose_block(%{"type" => "ordered-list", "items" => items}, :article)

      assert length(children) == 2

      assert Compose.compose_block(%{"type" => "ordered-list", "items" => items}, :article) ==
               Compose.compose_block(
                 %{"type" => "list", "ordered" => true, "items" => items},
                 :article
               )
    end
  end
end
