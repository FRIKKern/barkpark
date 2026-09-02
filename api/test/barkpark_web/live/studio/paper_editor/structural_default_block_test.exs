defmodule BarkparkWeb.Studio.PaperEditor.StructuralDefaultBlockTest do
  @moduledoc """
  block-insertability — the FIVE structural block types made canvas-insertable
  (action / figure / columns / terminal / table) each get a `default_block/2`
  clause mirroring the canvas slash-menu default (slash-insert.js canvasDefaultBlock),
  and each default block is ACCEPTED by `Render.Compose.compose_block/2` (renders to a
  real Pd node, NOT the unknown-block fallback). `section` already had a clause; it is
  covered here too for symmetry.

  Pure unit test — no DB / ConnCase. Pins the SERVER half of the mirror contract so the
  LiveView add-block path and the canvas "/" pick build the SAME minimal block.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias Barkpark.PortableDoc.Render.Compose

  @id "b-test-1"

  test "default_block(\"action\") is a flat empty href/label button" do
    assert Blocks.default_block("action", @id) ==
             %{"id" => @id, "type" => "action", "href" => "", "label" => ""}
  end

  test "default_block(\"figure\") wraps ONE empty-paragraph child, no caption" do
    block = Blocks.default_block("figure", @id)
    assert %{"id" => @id, "type" => "figure", "child" => child} = block
    assert %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]} = child
    refute Map.has_key?(block, "caption")
  end

  test "default_block(\"columns\") is two empty columns (a list of lists)" do
    assert Blocks.default_block("columns", @id) ==
             %{"id" => @id, "type" => "columns", "columns" => [[], []]}
  end

  test "default_block(\"terminal\") is an empty body with no chrome keys" do
    block = Blocks.default_block("terminal", @id)
    assert block == %{"id" => @id, "type" => "terminal", "children" => []}
    refute Map.has_key?(block, "title")
  end

  test "default_block(\"table\") is a headed 1-body 2-col grid with empty cells" do
    assert Blocks.default_block("table", @id) ==
             %{"id" => @id, "type" => "table", "head" => [[], []], "rows" => [[[], []]]}
  end

  # ── compose_block acceptance: each default renders to a real Pd node, not the
  #    unknown-block fallback (proves the render engine accepts the shape) ──

  test "compose_block accepts every structural default (no unknown-block fallback)" do
    for type <- ~w(action figure columns section terminal table) do
      block = Blocks.default_block(type, @id)
      node = Compose.compose_block(block)
      assert is_map(node), "#{type}: compose_block returned a node"

      # The unknown fallback is a `_raw` node carrying "Unsupported block:" copy (the
      # `bp-unknown-block` placeholder). figure/columns/terminal legitimately produce
      # `_raw` too, so the placeholder COPY — not the kind — is the discriminator.
      refute node |> inspect() |> String.contains?("Unsupported block"),
             "#{type}: default block degraded to the unsupported placeholder: #{inspect(node)}"
    end
  end

  # SUPERSEDED BY THE EMPTY-CHROME INVARIANT, not deleted. This pinned the
  # DEFECT: the canvas default action composed to a PdButton with href "" and
  # label "", which the walker painted as `<a href="#" class="bp-button"></a>` —
  # a zero-width CLICKABLE control on the PUBLIC reader. The default block itself
  # is unchanged (the mirror contract above still holds); what changed is what a
  # blank one composes to. This is the `image` precedent exactly: post-#1161 every
  # new paper seeds an asset-less featured image that likewise composes to "" and
  # is still fully editable, because the canvas builds its per-block DOM from the
  # `data-canvas-blocks` block DATA (paper.ex:656), never from the reader HTML.
  test "compose_block(action default) is the empty raw node — scaffolding, not a button" do
    node = Compose.compose_block(Blocks.default_block("action", @id))
    assert node == %{"kind" => "_raw", "html" => ""}
  end

  # The same doctrine reaches the default FIGURE through its child: the seeded
  # empty-paragraph child contributes no bytes and there is no caption, so the
  # frame is skipped rather than painting an empty bordered <figure>.
  test "compose_block(figure default) is the empty raw node — no empty bordered frame" do
    node = Compose.compose_block(Blocks.default_block("figure", @id))
    assert node == %{"kind" => "_raw", "html" => ""}
  end

  test "compose_block(table default) is a PdTable with a head + one body row" do
    node = Compose.compose_block(Blocks.default_block("table", @id))
    assert %{"kind" => "PdTable", "rows" => [[_, _]], "head" => [_, _]} = node
  end
end
