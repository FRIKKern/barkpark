defmodule BarkparkWeb.Studio.SharedPaperExpandableCanvasTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "nested canvas inherits root host eligibility instead of inferring it from paper type" do
    blocks = [
      %{
        "id" => "details",
        "type" => "expandable",
        "children" => [%{"id" => "nested", "type" => "paragraph", "content" => []}]
      }
    ]

    base = [slug: "doc", blocks: blocks, doc_type: "paper", paper_rev: 1]
    beta_html = render_component(&PaperEditor.paper_block_editor/1, base)

    paper_html =
      render_component(&PaperEditor.paper_block_editor/1, base ++ [canvas_eligible: true])

    refute beta_html =~ ~s(phx-hook="BarkparkPaperCanvas")
    assert beta_html =~ ~s(id="paper-ed-nested")
    assert paper_html =~ ~s(phx-hook="BarkparkPaperCanvas")
    assert paper_html =~ ~s(data-paper-container-id="details")
  end

  test "nested canvas echoes use collision-free expandable run ids and visible alias precedence" do
    blocks = [
      %{"id" => "top", "type" => "paragraph"},
      %{
        "id" => "details",
        "type" => "expandable",
        "children" => [
          %{"id" => "nested", "type" => "paragraph"},
          %{"id" => "chart", "type" => "bar-chart"},
          %{"id" => "stats", "type" => "stats"}
        ],
        "blocks" => [%{"id" => "hidden", "type" => "paragraph"}]
      }
    ]

    runs = Paper.canvas_echo_runs("paper", blocks)

    assert Enum.any?(runs, &(&1.run_id == "paper-run-0" and Enum.at(&1.blocks, 0)["id"] == "top"))

    assert Enum.any?(
             runs,
             &(&1.run_id == "paper-expandable-details-run-0" and
                 Enum.map(&1.blocks, fn block -> block["id"] end) == ["nested"])
           )

    assert Enum.any?(
             runs,
             &(&1.run_id == "paper-expandable-details-run-1" and
                 Enum.map(&1.blocks, fn block -> block["id"] end) == ["stats"])
           )

    refute Enum.any?(runs, &Enum.any?(&1.blocks, fn block -> block["id"] == "hidden" end))
  end

  test "server-painted nested fleet and dataviz blocks are traversed" do
    blocks = [
      %{
        "id" => "details",
        "type" => "expandable",
        "children" => [
          %{"id" => "stats", "type" => "stats"},
          %{"id" => "cards", "type" => "cards"},
          %{"id" => "lineage", "type" => "lineage"}
        ]
      }
    ]

    assert Enum.map(Paper.expandable_render_blocks(blocks), & &1["id"]) ==
             ["details", "stats", "cards", "lineage"]
  end
end
