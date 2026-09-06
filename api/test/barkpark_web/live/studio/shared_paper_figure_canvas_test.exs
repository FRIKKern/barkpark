defmodule BarkparkWeb.Studio.SharedPaperFigureCanvasTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "echoes a projected singular child in the figure namespace without mutating source" do
    figure = %{
      "id" => "figure",
      "type" => "figure",
      "caption" => "Caption",
      "child" => %{"type" => "paragraph", "content" => []}
    }

    original = figure
    runs = Paper.canvas_echo_runs("paper", [figure])

    assert Enum.find(
             runs,
             &(&1.run_id ==
                 PaperCanvas.run_id(PaperCanvas.figure_run_slug("paper", "figure"), 0))
           ).blocks == [
             %{"id" => "figure-child-0", "type" => "paragraph", "content" => []}
           ]

    assert figure == original
  end

  test "recurses through the child for deeper nested canvas runs" do
    figure = %{
      "id" => "figure",
      "type" => "figure",
      "child" => %{
        "id" => "details",
        "type" => "expandable",
        "children" => [%{"id" => "inner", "type" => "paragraph", "content" => []}]
      }
    }

    runs = Paper.canvas_echo_runs("paper", [figure])

    assert Enum.find(runs, &(&1.run_id == "paper-expandable-details-run-0")).blocks == [
             %{"id" => "inner", "type" => "paragraph", "content" => []}
           ]
  end

  test "server-painted traversal includes figure children and their visible descendants" do
    figure = %{
      "id" => "figure",
      "type" => "figure",
      "child" => %{
        "id" => "details",
        "type" => "expandable",
        "children" => [%{"id" => "cards", "type" => "cards"}]
      }
    }

    assert Enum.map(Paper.expandable_render_blocks([figure]), & &1["id"]) == [
             "figure",
             "details",
             "cards"
           ]
  end

  test "missing and malformed figure children remain opaque" do
    for figure <- [
          %{"id" => "missing", "type" => "figure"},
          %{"id" => "nil", "type" => "figure", "child" => nil},
          %{"id" => "scalar", "type" => "figure", "child" => "opaque"},
          %{"id" => "list", "type" => "figure", "child" => [%{"id" => "hidden"}]}
        ] do
      refute Enum.any?(
               Paper.canvas_echo_runs("paper", [figure]),
               &String.starts_with?(&1.run_id, PaperCanvas.figure_run_slug("paper", figure["id"]))
             )

      assert Paper.expandable_render_blocks([figure]) == [figure]
    end
  end
end
