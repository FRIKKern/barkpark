defmodule BarkparkWeb.Studio.StudioLive.TechnicalBlocksCanvasTest do
  @moduledoc """
  scaffy-backlog-blocks-editable-studio — the Elixir half of "diff + filetree are
  editable in BOTH Studio surfaces".

  The CLASSIC form half already ships (`TechnicalBlockEditor`, pinned by
  `technical_block_editor_test.exs`). This file pins the CANVAS half's two Elixir
  seams, the ones a JS test can never see:

    * CANVAS ELIGIBILITY — both types are in `@canvas_attr_atom_types`, so
      `partition_runs/1` FOLDS them into a prose run instead of emitting a
      `{:block, …}` boundary. Without the enrollment the canvas shows the read-only
      boundary widget and the bpDiff / bpFiletree node never mounts; the first test
      below is the one that reds.

    * THE SERVER PAINT — `push_block_renders/1` must emit a `bp:block-html` render
      for a top-level diff/filetree, because the node-view has NO client producer
      for their markup (canvas_reader_parity_gate_test.exs §3 forbids one). The
      painted bytes must be the READER's own `Render.render_block(block,
      %{style: :article})`. Without `@technical_render_types` the node-view's hole
      keeps its loading chip forever.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper, as: SharedPaper

  defp para(id), do: %{"id" => id, "type" => "paragraph", "content" => []}

  defp diff_block(id),
    do: %{
      "id" => id,
      "type" => "diff",
      "diff" => "@@ -1,2 +1,2 @@\n context\n-old\n+new",
      "file" => "lib/a.ex",
      "lang" => "elixir"
    }

  defp filetree_block(id),
    do: %{
      "id" => id,
      "type" => "filetree",
      "text" => "lib/\n├── a.ex ● covered",
      "legend" => "● covered"
    }

  describe "canvas eligibility (the attr-atom tier)" do
    test "a diff block alone rides a RUN, never a boundary" do
      block = diff_block("d1")
      assert PaperCanvas.partition_runs([block]) == [{:run, [block]}]
    end

    test "a filetree block alone rides a RUN, never a boundary" do
      block = filetree_block("f1")
      assert PaperCanvas.partition_runs([block]) == [{:run, [block]}]
    end

    test "both types INSIDE prose keep the run whole (they no longer split it)" do
      blocks = [para("p1"), diff_block("d1"), para("p2"), filetree_block("f1"), para("p3")]
      assert PaperCanvas.partition_runs(blocks) == [{:run, blocks}]
    end

    test "CONTROL: a still-splitting kind DOES emit a boundary (the run check has teeth)" do
      # A nested-structure field is deliberately NOT canvas-eligible. If this ever
      # rides a run too, the assertions above stop distinguishing enrolled from
      # unenrolled and go vacuous.
      composite = %{"id" => "c1", "type" => "composite", "fields" => []}

      assert PaperCanvas.partition_runs([para("p1"), composite]) == [
               {:run, [para("p1")]},
               {:block, composite}
             ]
    end
  end

  describe "the server paint (bp:block-html)" do
    test "fleet_render/2 paints a diff with the READER's own bytes" do
      block = diff_block("d1")
      render = SharedPaper.fleet_render(block, %{})

      assert render["block_id"] == "d1"

      assert render["html"] == Render.render_block(block, %{style: :article}),
             "the canvas paint forked from the reader — D8 demands ONE producer"

      assert render["html"] =~ "bp-" <> "diff",
             "the painted HTML is not the diff emitter's output — this check went vacuous"
    end

    test "fleet_render/2 paints a filetree with the READER's own bytes" do
      block = filetree_block("f1")
      render = SharedPaper.fleet_render(block, %{})

      assert render["block_id"] == "f1"
      assert render["html"] == Render.render_block(block, %{style: :article})
      assert render["html"] =~ "bp-" <> "filetree"
    end

    test "CONTROL: the paint is non-empty and type-specific (not one shared blob)" do
      diff_html = SharedPaper.fleet_render(diff_block("d1"), %{})["html"]
      tree_html = SharedPaper.fleet_render(filetree_block("f1"), %{})["html"]

      assert byte_size(diff_html) > 0
      assert byte_size(tree_html) > 0
      refute diff_html == tree_html
    end
  end
end
