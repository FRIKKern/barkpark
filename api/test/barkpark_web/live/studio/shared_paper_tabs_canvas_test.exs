defmodule BarkparkWeb.Studio.SharedPaperTabsCanvasTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "echoes follow tab identity through reorder and descend into nested containers" do
    rows = [
      %{"id" => "first", "blocks" => [paragraph("one")]},
      %{
        "id" => "second",
        "blocks" => [
          paragraph("two"),
          %{"type" => "expandable", "id" => "details", "children" => [paragraph("inner")]}
        ],
        "children" => [paragraph("opaque")]
      }
    ]

    build = fn rows -> [%{"id" => "tabs", "type" => "tabs", "tabs" => rows}] end
    runs = Paper.canvas_echo_runs("paper", build.(rows))

    assert Enum.find(runs, &(&1.blocks == [paragraph("one")]))

    assert Enum.find(runs, &(&1.run_id == "paper-expandable-details-run-0")).blocks == [
             paragraph("inner")
           ]

    refute Enum.any?(runs, &Enum.any?(&1.blocks, fn block -> block["id"] == "opaque" end))

    assert Map.new(runs, &{&1.run_id, &1.blocks}) ==
             Map.new(
               Paper.canvas_echo_runs("paper", build.(Enum.reverse(rows))),
               &{&1.run_id, &1.blocks}
             )
  end

  test "tabs only expose canonical list bodies, never children metadata or code-tabs" do
    for body <- [nil, false, [], "legacy", %{"type" => "paragraph", "id" => "scalar"}] do
      tabs = %{
        "id" => "tabs",
        "type" => "tabs",
        "tabs" => [
          %{"id" => "row", "blocks" => body, "children" => [paragraph("opaque")]}
        ]
      }

      assert Paper.canvas_echo_runs("paper", [tabs]) == []
      assert Paper.expandable_render_blocks([tabs]) == [tabs]
    end

    code = %{
      "id" => "code",
      "type" => "code-tabs",
      "tabs" => [%{"id" => "row", "blocks" => [paragraph("opaque")]}]
    }

    assert Paper.canvas_echo_runs("paper", [code]) == []
    assert Paper.expandable_render_blocks([code]) == [code]
  end

  test "server painted traversal includes canonical tab bodies recursively" do
    nested = %{
      "id" => "inner-tabs",
      "type" => "tabs",
      "tabs" => [
        %{"id" => "inner-row", "blocks" => [%{"id" => "stats", "type" => "stats"}]}
      ]
    }

    tabs = %{
      "id" => "tabs",
      "type" => "tabs",
      "tabs" => [
        %{"id" => "row", "blocks" => [nested], "children" => [paragraph("opaque")]}
      ]
    }

    assert Enum.map(Paper.expandable_render_blocks([tabs]), & &1["id"]) == [
             "tabs",
             "inner-tabs",
             "stats"
           ]
  end

  test "tab run namespace cannot collide with steps or ambiguous joined row identifiers" do
    refute PaperCanvas.tabs_run_slug("paper", "a-b", "c") ==
             PaperCanvas.tabs_run_slug("paper", "a", "b-c")

    refute PaperCanvas.tabs_run_slug("paper", "tabs", "row") ==
             PaperCanvas.steps_run_slug("paper", "tabs", "row")
  end

  defp paragraph(id), do: %{"type" => "paragraph", "id" => id, "content" => []}
end
