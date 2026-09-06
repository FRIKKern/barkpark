defmodule BarkparkWeb.Studio.SharedPaperStepsCanvasTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "row run identities are stable and unambiguous" do
    refute PaperCanvas.steps_run_slug("paper", "a-b", "c") ==
             PaperCanvas.steps_run_slug("paper", "a", "b-c")

    assert PaperCanvas.steps_run_slug("paper", "steps", "row") ==
             PaperCanvas.steps_run_slug("paper", "steps", "row")
  end

  test "echoes follow row identity through reorder and traverse nested expandables" do
    rows = [
      %{"id" => "first", "children" => [paragraph("one")]},
      %{
        "id" => "second",
        "blocks" => [
          paragraph("two"),
          %{"type" => "expandable", "id" => "details", "children" => [paragraph("inner")]}
        ]
      }
    ]

    build = fn rows -> [%{"id" => "steps", "type" => "steps", "steps" => rows}] end
    runs = Paper.canvas_echo_runs("paper", build.(rows))

    assert Enum.find(
             runs,
             &(&1.run_id ==
                 PaperCanvas.run_id(PaperCanvas.steps_run_slug("paper", "steps", "first"), 0))
           ).blocks == [paragraph("one")]

    assert Enum.find(runs, &(&1.run_id == "paper-expandable-details-run-0")).blocks == [
             paragraph("inner")
           ]

    assert Map.new(runs, &{&1.run_id, &1.blocks}) ==
             Map.new(
               Paper.canvas_echo_runs("paper", build.(Enum.reverse(rows))),
               &{&1.run_id, &1.blocks}
             )
  end

  test "empty or malformed authoritative children never expose shadow blocks" do
    for children <- [[], "invalid", %{}] do
      blocks = [
        %{
          "id" => "steps",
          "type" => "steps",
          "steps" => [
            %{"id" => "row", "children" => children, "blocks" => [paragraph("shadow")]}
          ]
        }
      ]

      assert Paper.canvas_echo_runs("paper", blocks) == []
    end
  end

  test "nil and false children use the visible blocks alias" do
    for children <- [nil, false] do
      blocks = [
        %{
          "id" => "steps",
          "type" => "steps",
          "steps" => [
            %{"id" => "row", "children" => children, "blocks" => [paragraph("visible")]}
          ]
        }
      ]

      assert [%{blocks: [%{"id" => "visible"}]}] = Paper.canvas_echo_runs("paper", blocks)
    end
  end

  defp paragraph(id), do: %{"type" => "paragraph", "id" => id, "content" => []}
end
