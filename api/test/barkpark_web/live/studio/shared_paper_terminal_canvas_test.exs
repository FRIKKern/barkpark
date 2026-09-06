defmodule BarkparkWeb.Studio.SharedPaperTerminalCanvasTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.PaperCanvas
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  test "echoes canonical Terminal children in a stable namespace without mutating source" do
    terminal = %{
      "id" => "terminal",
      "type" => "terminal",
      "title" => "Shell",
      "children" => [%{"type" => "paragraph", "content" => []}]
    }

    original = terminal
    runs = Paper.canvas_echo_runs("paper", [terminal])

    assert Enum.find(
             runs,
             &(&1.run_id ==
                 PaperCanvas.run_id(PaperCanvas.terminal_run_slug("paper", "terminal"), 0))
           ).blocks == [
             %{"id" => "terminal-0", "type" => "paragraph", "content" => []}
           ]

    assert terminal == original

    refute PaperCanvas.terminal_run_slug("paper", "a-b") ==
             PaperCanvas.terminal_run_slug("paper-a", "b")
  end

  test "recurses through canonical children for nested canvas runs and server paint" do
    terminal = %{
      "id" => "terminal",
      "type" => "terminal",
      "children" => [
        %{
          "id" => "details",
          "type" => "expandable",
          "children" => [%{"id" => "inner", "type" => "paragraph", "content" => []}]
        },
        %{"id" => "fleet", "type" => "fleet"},
        %{"id" => "stats", "type" => "stats"}
      ]
    }

    runs = Paper.canvas_echo_runs("paper", [terminal])

    assert Enum.find(runs, &(&1.run_id == "paper-expandable-details-run-0")).blocks == [
             %{"id" => "inner", "type" => "paragraph", "content" => []}
           ]

    assert Enum.map(Paper.expandable_render_blocks([terminal]), & &1["id"]) == [
             "terminal",
             "details",
             "inner",
             "fleet",
             "stats"
           ]
  end

  test "empty canonical Terminal emits no phantom run" do
    terminal = %{"id" => "terminal", "type" => "terminal", "children" => []}

    refute Enum.any?(
             Paper.canvas_echo_runs("paper", [terminal]),
             &String.starts_with?(&1.run_id, PaperCanvas.terminal_run_slug("paper", "terminal"))
           )

    assert Paper.expandable_render_blocks([terminal]) == [terminal]
  end

  test "legacy, dual, and malformed Terminal bodies remain opaque" do
    for terminal <- [
          %{"id" => "missing", "type" => "terminal"},
          %{"id" => "nil", "type" => "terminal", "children" => nil},
          %{"id" => "scalar", "type" => "terminal", "children" => "opaque"},
          %{"id" => "legacy", "type" => "terminal", "blocks" => [paragraph("hidden")]},
          %{
            "id" => "dual",
            "type" => "terminal",
            "children" => [paragraph("visible-if-canonical")],
            "blocks" => [paragraph("shadow")]
          }
        ] do
      refute Enum.any?(
               Paper.canvas_echo_runs("paper", [terminal]),
               &String.starts_with?(
                 &1.run_id,
                 PaperCanvas.terminal_run_slug("paper", terminal["id"])
               )
             )

      assert Paper.expandable_render_blocks([terminal]) == [terminal]
    end
  end

  defp paragraph(id), do: %{"id" => id, "type" => "paragraph", "content" => []}
end
