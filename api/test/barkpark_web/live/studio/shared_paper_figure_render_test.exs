defmodule BarkparkWeb.Studio.StudioLive.Shared.PaperFigureRenderTest do
  @moduledoc """
  editable-figure — the CHILD-paint channel. `push_block_renders` emits a
  `bp:block-html` render for every top-level `figure`, keyed by the FIGURE id, whose
  HTML is the figure's CHILD rendered ALONE (NOT the whole figure). This proves the
  hardest risk of the atom design: the canvas bpFigure atom paints the child into its
  hole, and its OWN editable `<figcaption>` input is the only caption — so the server
  must NEVER push a whole-figure render (which would carry a reader `<figcaption>`,
  DOUBLING the editable caption).

  Tests `figure_render/1` — the exact producer `push_block_renders` maps each figure
  through — so the assertion is pure (no socket/LiveView plumbing) and byte-couples the
  pushed child HTML to the reader's own `Render.render_block/2`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "a figure's pushed render is keyed by the FIGURE id and is the CHILD rendered alone (byte-identical to render_block)" do
    child = %{"id" => "c1", "type" => "heading", "level" => 2, "text" => "Inner"}

    figure = %{
      "id" => "fg1",
      "type" => "figure",
      "caption" => "Figure 2. A heading inside.",
      "child" => child
    }

    render = Paper.figure_render(figure)

    # Keyed by the FIGURE id (the bpFigure atom's paint hole is data-bp-fleet-id=<figure id>).
    assert render["block_id"] == "fg1"

    # BYTE-IDENTICAL to the reader's own child-only producer (rule 3 / D8).
    assert render["html"] == Render.render_block(child, %{style: :article})

    # CHILD-ONLY: the pushed HTML must carry NO reader <figcaption> (a whole-figure
    # render would — and that would DOUBLE the atom's editable caption input).
    refute render["html"] =~ "<figcaption"

    # The child itself is present (an honest paint, not an empty strip).
    assert render["html"] =~ "Inner"
  end

  test "an image-child figure paints the child's <img>, still no figcaption" do
    child = %{"id" => "c2", "type" => "image", "src" => "/a.png", "alt" => "map"}
    figure = %{"id" => "fg2", "type" => "figure", "child" => child}

    render = Paper.figure_render(figure)

    assert render["block_id"] == "fg2"
    assert render["html"] == Render.render_block(child, %{style: :article})
    refute render["html"] =~ "<figcaption"
  end

  test "a figure with a non-map / missing child paints \"\" (honest chip), never crashes" do
    assert Paper.figure_render(%{"id" => "fg3", "type" => "figure"}) == %{
             "block_id" => "fg3",
             "html" => ""
           }

    assert Paper.figure_render(%{"id" => "fg4", "type" => "figure", "child" => "not-a-map"}) ==
             %{"block_id" => "fg4", "html" => ""}
  end
end
