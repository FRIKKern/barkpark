defmodule Barkpark.PortableDoc.Render.InlineBlockWrapperUnwrapTest do
  # Pure, in-process — no DB, no plugins needed.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.Inline

  # A BLOCK-level node sitting inside an inline array carries its text one level
  # deeper than the inline clauses look, so it used to compose to "" — the reader
  # served HTTP 200 and showed an empty bullet while the prose sat on disk.
  #
  # Measured on the live corpus 2026-09-02: 75 list items across 4 published
  # papers rendered as <li><span></span></li>. Two wrappers, and the split is
  # exact with no remainder:
  #   56 items  "paragraph"  — felix-pristine-wave-23-2026-07-28 (32),
  #                            epic-cycle-distribution-wave-2026-08-12 (24)
  #   19 items  "list-item"  — search-template-wave-2026-08-18-audit (13),
  #                            cloud-console-hardening-wave-75-2026-08-18 (6)
  #
  # The bodies below are the real stored text of two of those items.

  @paragraph_wrapped_text "Denominator, re-derived from live L1: 72 done, 38 open, 6 considering, 1 cancelled (NOT child_count 117)."
  @list_item_wrapped_text "The blind window is 8 days 17 hours, not 5."

  defp paragraph_wrapper(text) do
    %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
  end

  defp list_item_wrapper(text) do
    %{"type" => "list-item", "content" => [%{"type" => "text", "value" => text}]}
  end

  describe "a block-level wrapper inside an inline array" do
    test "paragraph-wrapped: the text survives instead of composing to nothing" do
      assert Inline.compose_inline_children([paragraph_wrapper(@paragraph_wrapped_text)]) == [
               @paragraph_wrapped_text
             ]
    end

    test "list-item-wrapped: the text survives instead of composing to nothing" do
      assert Inline.compose_inline_children([list_item_wrapper(@list_item_wrapped_text)]) == [
               @list_item_wrapped_text
             ]
    end

    # The bug as the corpus actually carries it: the wrapper is the sole member
    # of a list item's inline array. Asserting on the composed PdNode tree keeps
    # this honest — a golden that only checked "no exception" would pass on a
    # renderer that emitted an empty span, which is precisely the old behaviour.
    test "a list whose items are paragraph-wrapped renders its bullets" do
      block = %{
        "type" => "list",
        "ordered" => false,
        "items" => [[paragraph_wrapper(@paragraph_wrapped_text)]]
      }

      result = Compose.compose_block(block, :article)

      assert result["kind"] == "PdList"

      [item] = result["children"]
      assert item["kind"] == "PdListItem"
      assert flatten_text(item) == @paragraph_wrapped_text
    end

    test "a list whose items are list-item-wrapped renders its bullets" do
      block = %{
        "type" => "list",
        "ordered" => false,
        "items" => [[list_item_wrapper(@list_item_wrapped_text)]]
      }

      result = Compose.compose_block(block, :article)

      [item] = result["children"]
      assert flatten_text(item) == @list_item_wrapped_text
    end
  end

  # compose_inline_children/1 is the SHARED inline walk — it serves paragraphs,
  # headings, list items and callouts alike. These two prove the fix lives in
  # that shared walk and not in the list path: a fix special-cased to
  # normalize_list_item/1 would leave both of these blank and still green the
  # list tests above.
  describe "the fix is in the shared walk, not the list path" do
    test "a HEADING carrying the same wrapper renders its text" do
      block = %{"type" => "heading", "level" => 2, "content" => [paragraph_wrapper("Wrapped heading")]}

      assert flatten_text(Compose.compose_block(block, :article)) == "Wrapped heading"
    end

    test "a PARAGRAPH carrying the same wrapper renders its text" do
      block = %{"type" => "paragraph", "content" => [paragraph_wrapper("Wrapped paragraph")]}

      assert flatten_text(Compose.compose_block(block, :article)) == "Wrapped paragraph"
    end
  end

  describe "the unwrap is bounded" do
    # One level only. A deeper nest is a separate finding with its own row, not
    # something this walk recurses into.
    test "it unwraps exactly ONE level, never recursing" do
      doubly = %{"type" => "paragraph", "content" => [paragraph_wrapper("deep")]}

      # The inner wrapper is exposed, not resolved — one level, as ruled.
      assert Inline.compose_inline_children([doubly]) == [""]
    end

    # Guard against the unwrap widening into "any node with a content key".
    # A block node WITHOUT content keeps today's behaviour.
    test "a wrapper with EMPTY content is left exactly as it was" do
      empty = %{"type" => "paragraph", "content" => []}

      assert Inline.compose_inline_children([empty]) == [""]
    end

    test "a canonical inline array is untouched — byte-identical to before" do
      canonical = [
        %{"type" => "text", "value" => "plain "},
        %{"type" => "strong", "children" => [%{"type" => "text", "value" => "bold"}]}
      ]

      assert Inline.compose_inline_children(canonical) ==
               Enum.map(canonical, &Inline.compose_inline(&1, false))
    end
  end

  # Collapse a composed PdNode tree to its text, so an assertion fails on
  # CONTENT loss rather than on tree shape.
  defp flatten_text(%{"children" => children}) when is_list(children) do
    Enum.map_join(children, "", &flatten_text/1)
  end

  defp flatten_text(s) when is_binary(s), do: s
  defp flatten_text(_), do: ""
end
