defmodule BarkparkWeb.Studio.PaperEditor.ContainerBlocksTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "featured links can be enabled and cleared without losing legacy metadata" do
    ref = %{"slug" => "day", "featured" => true, "analytics_key" => "keep"}
    block = %{"type" => "paper-links", "refs" => [ref]}
    params = %{"ref-count" => "1", "ref-0-slug" => "day"}

    assert [%{"featured" => true}] = Blocks.build_block_patch(block, params)["refs"]

    assert [%{"featured" => false, "analytics_key" => "keep"}] =
             Blocks.build_block_patch(block, Map.put(params, "ref-0-featured", "false"))["refs"]

    legacy = %{"type" => "paper-links", "refs" => ["day"]}

    assert ["day"] =
             Blocks.build_block_patch(legacy, Map.put(params, "ref-0-featured", "false"))["refs"]

    assert [%{"slug" => "day", "featured" => true}] =
             Blocks.build_block_patch(legacy, Map.put(params, "ref-0-featured", "true"))["refs"]
  end

  test "paper-links clearing is explicit and rebuilt references retain unknown metadata" do
    block = %{
      "type" => "paper-links",
      "title" => "Before",
      "description" => "Before",
      "layout" => "timeline",
      "refs" => [%{"slug" => "day", "title" => "Day", "unknown" => "keep"}]
    }

    patch =
      Blocks.build_block_patch(block, %{
        "title" => "",
        "description" => "",
        "layout" => "",
        "ref-count" => "1",
        "ref-0-slug" => "day",
        "ref-0-title" => "Updated"
      })

    assert patch["title"] == nil
    assert patch["description"] == nil
    assert patch["layout"] == nil
    assert [%{"slug" => "day", "title" => "Updated", "unknown" => "keep"}] = patch["refs"]
  end

  test "bar-chart patch merges typed values into each original bar" do
    block = %{
      "type" => "bar-chart",
      "bars" => [
        %{"label" => "feat", "value" => 1, "color" => "mint"},
        %{"label" => "fix", "value" => 2}
      ]
    }

    patch =
      Blocks.build_block_patch(block, %{
        "title" => "Totals",
        "max" => "9.5",
        "values" => "true",
        "bar-count" => "2",
        "bar-0-label" => "feat",
        "bar-0-value" => "3",
        "bar-1-label" => "fix",
        "bar-1-value" => "4.25"
      })

    assert patch["max"] == 9.5
    assert patch["values"] == true
    assert [%{"value" => 3, "color" => "mint"}, %{"value" => 4.25}] = patch["bars"]
  end

  test "first add starts from an empty collection and submitted counts cannot fabricate rows" do
    assert %{"refs" => [""]} =
             Blocks.build_block_patch(%{"type" => "paper-links", "refs" => []}, %{
               "ref-count" => "999999999",
               "ref-action" => "add"
             })

    assert %{"bars" => [%{"label" => "", "value" => 0}]} =
             Blocks.build_block_patch(%{"type" => "bar-chart", "bars" => []}, %{
               "bar-count" => "999999999",
               "bar-action" => "add"
             })
  end

  test "invalid remove indices preserve rows and blank bar title and max clear explicitly" do
    ref = %{"slug" => "day", "unknown" => "keep"}
    bar = %{"label" => "feat", "value" => 1, "color" => "mint"}

    assert %{"refs" => [^ref]} =
             Blocks.build_block_patch(%{"type" => "paper-links", "refs" => [ref]}, %{
               "ref-count" => "999999999",
               "ref-action" => "remove:-1"
             })

    patch =
      Blocks.build_block_patch(
        %{"type" => "bar-chart", "title" => "Before", "max" => 9, "bars" => [bar]},
        %{
          "title" => "   ",
          "max" => "",
          "bar-count" => "999999999",
          "bar-action" => "remove:-1"
        }
      )

    assert patch["title"] == nil
    assert patch["max"] == nil
    assert patch["bars"] == [bar]
  end

  test "canvas run context accepts only both valid wire fields" do
    assert {:ok, nil} = Blocks.canvas_run_context(%{"ops" => []})

    assert {:ok, %{container_id: "details", container_run_ids: ["a", "b"]}} =
             Blocks.canvas_run_context(%{
               "container_id" => "details",
               "container_run_ids" => ["a", "b"]
             })

    for invalid <- [
          %{"container_id" => "details"},
          %{"container_run_ids" => ["a"]},
          %{"container_id" => "", "container_run_ids" => ["a"]},
          %{"container_id" => "details", "container_run_ids" => []},
          %{"container_id" => "details", "container_run_ids" => ["a", "a"]},
          %{"container_id" => "details", "container_run_ids" => [""]}
        ] do
      assert {:error, :invalid_container_context} = Blocks.canvas_run_context(invalid)
    end
  end
end
