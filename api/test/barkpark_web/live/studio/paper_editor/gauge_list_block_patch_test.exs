defmodule BarkparkWeb.Studio.PaperEditor.GaugeListBlockPatchTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "effective mode and rows match renderer inference without rewriting legacy shapes" do
    assert Blocks.gauge_list_mode(%{"rows" => []}) == "share"
    assert Blocks.gauge_list_mode(%{"rows" => [], "snapshot" => []}) == "count"
    assert Blocks.gauge_list_mode(%{"mode" => " SHARE ", "snapshot" => []}) == "share"
    assert Blocks.gauge_list_mode(%{"mode" => "unknown", "rows" => []}) == "share"
    assert Blocks.gauge_list_group_by(%{}) == "status"
    assert Blocks.gauge_list_group_by(%{"groupBy" => " STATUS "}) == "STATUS"

    assert Blocks.gauge_list_rows(%{}) == []
    assert Blocks.gauge_list_rows(%{"rows" => nil}) == []

    assert Blocks.gauge_list_rows(%{"rows" => [%{"label" => "One"}, "legacy"]}) == [
             %{"label" => "One"},
             "legacy"
           ]

    assert Blocks.gauge_list_rows(%{"rows" => %{"label" => "scalar"}}) == [
             %{"label" => "scalar"}
           ]

    assert {:ok, %{}} =
             Blocks.validate_block_patch(%{"type" => "gauge-list", "rows" => []}, %{
               "mode" => "share",
               "gauge-count" => "0"
             })

    assert {:ok, %{"rows" => [%{"label" => "", "value" => 0, "note" => ""}]}} =
             Blocks.validate_block_patch(%{"type" => "gauge-list", "rows" => nil}, %{
               "gauge-count" => "0",
               "gauge-action" => "add"
             })

    assert {:ok, %{}} =
             Blocks.validate_block_patch(%{"type" => "gauge-list", "snapshot" => []}, %{
               "mode" => "count",
               "groupBy" => "status"
             })
  end

  test "share edits preserve metadata and unchanged legacy field shapes" do
    first = %{
      "label" => 42,
      "value" => "legacy-number",
      "note" => "Keep",
      "metadata" => %{"source" => "authored"}
    }

    second = %{"label" => "Second", "value" => 2, "note" => ""}

    block = %{
      "type" => "gauge-list",
      "mode" => " SHARE ",
      "title" => 7,
      "max" => "legacy-max",
      "rows" => [first, second],
      "unknown" => true
    }

    assert {:ok, %{}} =
             Blocks.validate_block_patch(block, %{
               "mode" => "share",
               "title" => "7",
               "max" => "legacy-max",
               "gauge-count" => "2",
               "gauge-0-label" => "42",
               "gauge-0-value" => "legacy-number",
               "gauge-0-note" => "Keep",
               "gauge-1-label" => "Second",
               "gauge-1-value" => "2",
               "gauge-1-note" => ""
             })

    params = %{
      "title" => "Capacity",
      "max" => "12.5",
      "gauge-count" => "2",
      "gauge-0-label" => "Primary",
      "gauge-0-value" => "3.5",
      "gauge-0-note" => "Updated"
    }

    assert {:ok, %{"title" => "Capacity", "max" => 12.5, "rows" => [edited, ^second]}} =
             Blocks.validate_block_patch(block, params)

    assert edited == %{
             "label" => "Primary",
             "value" => 3.5,
             "note" => "Updated",
             "metadata" => %{"source" => "authored"}
           }
  end

  test "share row actions are ordered, fenced by exact count, and preserve rows" do
    first = %{"label" => "First", "value" => 1, "extra" => 1}
    second = %{"label" => "Second", "value" => 2, "extra" => 2}
    block = %{"type" => "gauge-list", "mode" => "share", "rows" => [first, second]}

    assert {:ok, %{"rows" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, %{
               "gauge-count" => "2",
               "gauge-action" => "up:1"
             })

    assert {:ok, %{"rows" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, %{
               "gauge-count" => "2",
               "gauge-action" => "down:0"
             })

    assert {:ok, %{"rows" => [^second]}} =
             Blocks.validate_block_patch(block, %{
               "gauge-count" => "2",
               "gauge-action" => "remove:0"
             })

    assert {:ok, %{"rows" => [^first, ^second, added]}} =
             Blocks.validate_block_patch(block, %{
               "gauge-count" => "2",
               "gauge-action" => "add"
             })

    assert added == %{"label" => "", "value" => 0, "note" => ""}
  end

  test "count edits never include the authoritative snapshot and mode switches preserve concealed data" do
    snapshot = [%{"status" => "done", "opaque" => [1, 2]}]

    count = %{
      "type" => "gauge-list",
      "mode" => "count",
      "title" => "Tasks",
      "groupBy" => "status",
      "snapshot" => snapshot,
      "rows" => [%{"label" => "Concealed", "value" => 4}]
    }

    assert {:ok, %{"title" => "Work", "groupBy" => "priority"} = patch} =
             Blocks.validate_block_patch(count, %{
               "title" => "Work",
               "groupBy" => "priority"
             })

    refute Map.has_key?(patch, "snapshot")
    refute Map.has_key?(patch, "rows")

    assert {:ok, %{"mode" => "share"}} =
             Blocks.validate_block_patch(count, %{
               "mode" => "share",
               "groupBy" => "status"
             })

    share = %{
      "type" => "gauge-list",
      "mode" => "share",
      "max" => 10,
      "rows" => [%{"label" => "One", "value" => 1}],
      "snapshot" => snapshot,
      "groupBy" => "status"
    }

    assert {:ok, %{"mode" => "count"}} =
             Blocks.validate_block_patch(share, %{
               "mode" => "count",
               "max" => "10",
               "gauge-count" => "1",
               "gauge-0-label" => "One",
               "gauge-0-value" => "1"
             })

    source =
      Blocks.block_form_source(%{
        "block_id" => "gauge-1",
        "title" => "Resolved",
        "groupBy" => "worker",
        "snapshot" => [%{"status" => "forged"}],
        "if_rev" => "transport",
        "request_id" => "transport"
      })

    assert {:ok,
            %{
              "op" => "patch-block",
              "id" => "gauge-1",
              "patch" => %{"title" => "Resolved", "groupBy" => "worker"}
            }} = Blocks.resolve_block_form([Map.put(count, "id", "gauge-1")], source)
  end

  test "scalar-only forms preserve malformed legacy rows exactly" do
    for rows <- ["legacy", [%{"label" => "Valid", "value" => 1}, "legacy"]] do
      block = %{"type" => "gauge-list", "mode" => "share", "title" => "Before", "rows" => rows}

      assert {:ok, %{"title" => "After", "max" => 12}} =
               Blocks.validate_block_patch(block, %{
                 "title" => "After",
                 "mode" => "share",
                 "max" => "12"
               })

      assert block["rows"] == rows
    end
  end

  test "malformed collections, actions, text, options, and changed numbers fail closed" do
    share = %{
      "type" => "gauge-list",
      "mode" => "share",
      "rows" => [%{"label" => "One", "value" => 1}]
    }

    invalid = [
      {%{"gauge-count" => "0"}, {:malformed_collection, "rows"}},
      {%{"gauge-count" => "1", "gauge-action" => "remove:8"}, {:malformed_collection, "rows"}},
      {%{"gauge-count" => "1", "gauge-1-label" => "stale"}, {:malformed_collection, "rows"}},
      {%{"gauge-count" => "1", "gauge-0-label" => %{"bad" => true}}, {:invalid_text, "rows"}},
      {%{"gauge-count" => "1", "gauge-0-note" => ["bad"]}, {:invalid_text, "rows"}},
      {%{"gauge-count" => "1", "gauge-0-value" => "NaN"}, {:invalid_number, "rows"}},
      {%{"max" => "0"}, {:invalid_number, "max"}},
      {%{"max" => "-1"}, {:invalid_number, "max"}},
      {%{"mode" => "ratio"}, {:invalid_option, "mode"}},
      {%{"title" => %{"bad" => true}}, {:invalid_text, "title"}}
    ]

    for {params, reason} <- invalid do
      assert {:error, ^reason} = Blocks.validate_block_patch(share, params)
      assert Blocks.build_block_patch(share, params) == %{}
    end

    assert {:error, {:malformed_collection, "rows"}} =
             Blocks.validate_block_patch(%{share | "rows" => %{"label" => "bad"}}, %{
               "gauge-count" => "1"
             })

    count = %{"type" => "gauge-list", "mode" => "count", "groupBy" => "legacy"}
    assert {:ok, %{}} = Blocks.validate_block_patch(count, %{"groupBy" => "legacy"})

    assert {:error, {:invalid_option, "groupBy"}} =
             Blocks.validate_block_patch(count, %{"groupBy" => "team"})

    assert {:error, {:malformed_collection, "rows"}} =
             Blocks.validate_block_patch(count, %{"gauge-count" => "0"})
  end

  test "a fresh gauge list uses the canonical editable share shape" do
    assert Blocks.default_block("gauge-list", "gauge-new") == %{
             "id" => "gauge-new",
             "type" => "gauge-list",
             "title" => "",
             "mode" => "share",
             "rows" => [%{"label" => "", "value" => 0, "note" => ""}]
           }
  end
end
