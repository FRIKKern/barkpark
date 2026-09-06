defmodule BarkparkWeb.Studio.SharedPaperSectionColumnsCanvasTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "echoes projected Section children in a stable namespace without mutating source" do
    section = %{
      "id" => "section",
      "type" => "section",
      "title" => "Keep",
      "blocks" => [%{"type" => "paragraph", "content" => []}]
    }

    original = section
    runs = Paper.canvas_echo_runs("paper", [section])

    assert Enum.find(
             runs,
             &(&1.run_id ==
                 PaperCanvas.run_id(PaperCanvas.section_run_slug("paper", "section"), 0))
           ).blocks == [
             %{"id" => "section-0", "type" => "paragraph", "content" => []}
           ]

    assert section == original
  end

  test "echoes every valid Columns body by exact index and recurses into nested containers" do
    grid = %{
      "id" => "grid",
      "type" => "columns",
      "columns" => [
        [%{"type" => "paragraph", "content" => []}],
        %{"opaque" => true},
        [
          %{
            "id" => "details",
            "type" => "expandable",
            "children" => [%{"id" => "inner", "type" => "paragraph", "content" => []}]
          }
        ]
      ]
    }

    runs = Paper.canvas_echo_runs("paper", [grid])

    assert Enum.find(
             runs,
             &(&1.run_id ==
                 PaperCanvas.run_id(PaperCanvas.columns_run_slug("paper", "grid", 0), 0))
           ).blocks == [
             %{"id" => "grid-column-0-0", "type" => "paragraph", "content" => []}
           ]

    refute Enum.any?(runs, fn run ->
             String.starts_with?(run.run_id, PaperCanvas.columns_run_slug("paper", "grid", 1))
           end)

    assert Enum.find(runs, &(&1.run_id == "paper-expandable-details-run-0")).blocks == [
             %{"id" => "inner", "type" => "paragraph", "content" => []}
           ]
  end

  test "grid Sections skip direct runs but recurse cells without sorting placement metadata" do
    first = %{
      "id" => "first",
      "type" => "paragraph",
      "content" => [],
      "order" => 2,
      "span" => 2
    }

    second = %{
      "id" => "details",
      "type" => "expandable",
      "children" => [%{"id" => "inner", "type" => "paragraph", "content" => []}],
      "order" => -1
    }

    section = %{
      "id" => "section",
      "type" => "section",
      "layout" => %{"mode" => "grid", "tracks" => 2},
      "blocks" => [first, second]
    }

    runs = Paper.canvas_echo_runs("paper", [section])

    refute Enum.any?(runs, fn run ->
             String.starts_with?(run.run_id, PaperCanvas.section_run_slug("paper", "section"))
           end)

    assert Enum.find(runs, &(&1.run_id == "paper-expandable-details-run-0")).blocks == [
             %{"id" => "inner", "type" => "paragraph", "content" => []}
           ]

    assert section["blocks"] == [first, second]
  end

  test "server-painted traversal includes canonical Section and Columns descendants only" do
    cards = %{"id" => "cards", "type" => "cards"}
    stats = %{"id" => "stats", "type" => "stats"}

    tree = %{
      "id" => "section",
      "type" => "section",
      "children" => [%{"id" => "section-shadow", "type" => "cards"}],
      "blocks" => [
        cards,
        %{
          "id" => "grid",
          "type" => "columns",
          "blocks" => [%{"id" => "columns-shadow", "type" => "stats"}],
          "columns" => [[stats], %{"id" => "opaque-row", "type" => "cards"}]
        }
      ]
    }

    assert Enum.map(Paper.expandable_render_blocks([tree]), & &1["id"]) == [
             "section",
             "cards",
             "grid",
             "stats"
           ]
  end

  test "malformed canonical bodies and opaque aliases never gain nested echoes or paints" do
    for block <- [
          %{
            "id" => "section",
            "type" => "section",
            "blocks" => "opaque",
            "children" => [paragraph("hidden")]
          },
          %{
            "id" => "grid",
            "type" => "columns",
            "columns" => "opaque",
            "blocks" => [paragraph("hidden")]
          },
          %{
            "id" => "grid",
            "type" => "columns",
            "columns" => [%{"opaque" => [paragraph("hidden")]}],
            "children" => [paragraph("also-hidden")]
          }
        ] do
      runs = Paper.canvas_echo_runs("paper", [block])

      refute Enum.any?(runs, fn run ->
               String.starts_with?(
                 run.run_id,
                 PaperCanvas.section_run_slug("paper", block["id"])
               ) or
                 String.starts_with?(
                   run.run_id,
                   PaperCanvas.columns_run_slug("paper", block["id"], 0)
                 )
             end)

      assert Paper.expandable_render_blocks([block]) == [block]
    end
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "content" => []}
end
