defmodule BarkparkWeb.Studio.PaperEditor.StepsContainerContextTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "host parser preserves legacy shape and delegates the strict steps shape" do
    assert {:ok, nil} = Blocks.canvas_run_context(%{"ops" => []})

    assert {:ok, %{container_id: "details", container_run_ids: ["a", "b"]}} =
             Blocks.canvas_run_context(%{
               "container_id" => "  details  ",
               "container_run_ids" => ["a", "b"]
             })

    assert {:ok,
            %{
              container_kind: "steps",
              container_id: "procedure",
              container_row_id: "row-a",
              container_run_ids: ["a", "b"]
            }} =
             Blocks.canvas_run_context(%{
               "container_kind" => "steps",
               "container_id" => "  procedure  ",
               "container_row_id" => "row-a",
               "container_run_ids" => ["a", "b"]
             })
  end

  test "host parser rejects partial, mixed and unknown context markers" do
    invalid = [
      %{"container_kind" => "steps"},
      %{"container_row_id" => "row-a"},
      %{
        "container_id" => "procedure",
        "container_run_ids" => ["a"],
        "container_row_id" => "row-a"
      },
      %{"container_kind" => "steps", "container_id" => "procedure", "container_run_ids" => ["a"]},
      %{
        "container_kind" => "expandable",
        "container_id" => "details",
        "container_run_ids" => ["a"]
      },
      %{
        "container_kind" => "unknown",
        "container_id" => "procedure",
        "container_row_id" => "row-a",
        "container_run_ids" => ["a"]
      },
      %{
        "container_kind" => "steps",
        "container_id" => "procedure",
        "container_row_id" => "",
        "container_run_ids" => ["a"]
      }
    ]

    for params <- invalid do
      assert {:error, :invalid_container_context} = Blocks.canvas_run_context(params)
    end
  end
end
