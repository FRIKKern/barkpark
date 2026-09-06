defmodule BarkparkWeb.Studio.PaperEditor.ContextualProgressNavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor

  test "toc keeps its canonical preview visible above closed typed controls" do
    block = %{
      "id" => "outline",
      "type" => "toc",
      "depth" => 2,
      "numbered" => true,
      "sticky" => true,
      "items" => [
        %{"text" => "Start", "level" => 2, "anchor" => "start"},
        "legacy entry"
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

    assert html =~ Render.render_block(block, %{style: :article})
    assert html =~ ~s(data-test-id="paper-toc-preview")
    assert html =~ ~s(id="toc-form-outline")
    assert html =~ ~s(class="bp-paper-contextual-controls")
    assert html =~ "ignore_attrs"
    assert html =~ ~s(name="depth")
    assert html =~ ~s(name="numbered" value="false")
    assert html =~ ~s(name="numbered" value="true")
    assert html =~ ~s(name="sticky" value="false")
    assert html =~ ~s(name="sticky" value="true")
    assert html =~ ~s(name="toc-count" value="2")

    for field <- ~w(text level anchor) do
      assert html =~ ~s(name="toc-0-#{field}")
    end

    assert html =~ ~s(data-test-id="paper-toc-legacy-row")
    refute html =~ "blocks are not editable yet"
  end

  test "criteria progress keeps its canonical preview visible above closed typed controls" do
    block = %{
      "id" => "progress",
      "type" => "criteria-progress",
      "detail" => "total",
      "rows" => [
        %{"label" => "Evidence", "met" => 2, "total" => 3},
        17
      ]
    }

    html = render_component(&PaperEditor.paper_block_fields/1, %{block: block})

    assert html =~ Render.render_block(block, %{style: :article})
    assert html =~ ~s(data-test-id="paper-criteria-progress-preview")
    assert html =~ ~s(id="criteria-progress-form-progress")
    assert html =~ ~s(name="detail")
    assert html =~ ~s(name="criterion-count" value="2")

    for field <- ~w(label met total) do
      assert html =~ ~s(name="criterion-0-#{field}")
    end

    assert html =~ ~s(data-test-id="paper-criteria-progress-legacy-row")
    assert html =~ "ignore_attrs"
    refute html =~ "blocks are not editable yet"
  end

  test "toc patch preserves unknown fields, legacy rows, no-op shapes, and supports actions" do
    first = %{
      "text" => 42,
      "level" => "2x",
      "anchor" => "start",
      "metadata" => "keep"
    }

    second = %{"text" => "Next", "level" => 3, "anchor" => "next"}

    block = %{
      "type" => "toc",
      "depth" => "2",
      "numbered" => "true",
      "items" => [first, "legacy", second]
    }

    assert {:ok, %{}} =
             Blocks.validate_block_patch(block, %{
               "depth" => "2",
               "numbered" => "false",
               "toc-count" => "3",
               "toc-0-text" => "42",
               "toc-0-level" => "2x",
               "toc-0-anchor" => "start",
               "toc-2-text" => "Next",
               "toc-2-level" => "3",
               "toc-2-anchor" => "next"
             })

    assert {:ok, %{"items" => [^first, ^second, "legacy"]}} =
             Blocks.validate_block_patch(block, %{
               "toc-count" => "3",
               "toc-action" => "up:2"
             })

    assert {:ok, %{"items" => ["legacy", ^first, ^second]}} =
             Blocks.validate_block_patch(block, %{
               "toc-count" => "3",
               "toc-action" => "down:0"
             })

    assert {:ok, %{"items" => [^first, ^second]}} =
             Blocks.validate_block_patch(block, %{
               "toc-count" => "3",
               "toc-action" => "remove:1"
             })

    assert {:ok, %{"items" => [^first, "legacy", ^second, added]}} =
             Blocks.validate_block_patch(block, %{
               "toc-count" => "3",
               "toc-action" => "add"
             })

    assert added == %{"text" => "", "level" => 1, "anchor" => ""}

    assert {:ok,
            %{
              "depth" => 4,
              "numbered" => true,
              "sticky" => true,
              "items" => [edited, "legacy", ^second]
            }} =
             Blocks.validate_block_patch(block, %{
               "depth" => "4",
               "numbered" => "true",
               "sticky" => "true",
               "toc-count" => "3",
               "toc-0-text" => "Overview",
               "toc-0-level" => "3",
               "toc-0-anchor" => "overview"
             })

    assert edited == %{
             "text" => "Overview",
             "level" => 3,
             "anchor" => "overview",
             "metadata" => "keep"
           }
  end

  test "criteria progress patch preserves unknown fields, legacy rows, no-op shapes, and supports actions" do
    first = %{"label" => 42, "met" => "2", "total" => 5.0, "metadata" => "keep"}
    second = %{"label" => "Done", "met" => 1, "total" => 1}

    block = %{
      "type" => "criteria-progress",
      "detail" => "legacy",
      "rows" => [first, "legacy", second]
    }

    assert {:ok, %{}} =
             Blocks.validate_block_patch(block, %{
               "detail" => "legacy",
               "criterion-count" => "3",
               "criterion-0-label" => "42",
               "criterion-0-met" => "2",
               "criterion-0-total" => "5.0",
               "criterion-2-label" => "Done",
               "criterion-2-met" => "1",
               "criterion-2-total" => "1"
             })

    assert {:ok, %{"rows" => [^first, ^second, "legacy"]}} =
             Blocks.validate_block_patch(block, %{
               "criterion-count" => "3",
               "criterion-action" => "up:2"
             })

    assert {:ok, %{"rows" => ["legacy", ^first, ^second]}} =
             Blocks.validate_block_patch(block, %{
               "criterion-count" => "3",
               "criterion-action" => "down:0"
             })

    assert {:ok, %{"rows" => [^first, ^second]}} =
             Blocks.validate_block_patch(block, %{
               "criterion-count" => "3",
               "criterion-action" => "remove:1"
             })

    assert {:ok, %{"rows" => [^first, "legacy", ^second, added]}} =
             Blocks.validate_block_patch(block, %{
               "criterion-count" => "3",
               "criterion-action" => "add"
             })

    assert added == %{"label" => "", "met" => 0, "total" => 1}

    assert {:ok, %{"detail" => "total", "rows" => [edited, "legacy", ^second]}} =
             Blocks.validate_block_patch(block, %{
               "detail" => "total",
               "criterion-count" => "3",
               "criterion-0-label" => "Evidence",
               "criterion-0-met" => "2.5",
               "criterion-0-total" => "6"
             })

    assert edited == %{
             "label" => "Evidence",
             "met" => 2.5,
             "total" => 6,
             "metadata" => "keep"
           }
  end

  test "collection counts and changed numeric values fail closed" do
    toc = %{"type" => "toc", "depth" => 2, "items" => [%{"text" => "One", "level" => 1}]}

    progress = %{
      "type" => "criteria-progress",
      "rows" => [%{"label" => "One", "met" => 0, "total" => 1}]
    }

    for params <- [
          %{"toc-count" => "0", "toc-action" => "add"},
          %{"toc-0-text" => "Lost"}
        ] do
      assert {:error, {:malformed_collection, "items"}} = Blocks.validate_block_patch(toc, params)
    end

    assert {:error, {:invalid_number, "depth"}} =
             Blocks.validate_block_patch(toc, %{"depth" => "0"})

    assert {:error, {:invalid_number, "items"}} =
             Blocks.validate_block_patch(toc, %{
               "toc-count" => "1",
               "toc-0-level" => "nope"
             })

    assert {:error, {:malformed_collection, "rows"}} =
             Blocks.validate_block_patch(progress, %{
               "criterion-count" => "999999999",
               "criterion-action" => "remove:0"
             })

    assert {:error, {:invalid_number, "rows"}} =
             Blocks.validate_block_patch(progress, %{
               "criterion-count" => "1",
               "criterion-0-met" => "NaN"
             })
  end

  test "toc and criteria progress reject malformed text and checkbox payloads" do
    toc = %{
      "type" => "toc",
      "items" => [%{"text" => "One", "level" => 1, "anchor" => "one"}]
    }

    progress = %{
      "type" => "criteria-progress",
      "detail" => "rows",
      "rows" => [%{"label" => "One", "met" => 0, "total" => 1}]
    }

    for {params, reason} <- [
          {%{"numbered" => "garbage"}, {:invalid_boolean, "numbered"}},
          {%{"sticky" => %{"value" => true}}, {:invalid_boolean, "sticky"}},
          {%{"toc-count" => "1", "toc-0-text" => %{"value" => "bad"}}, {:invalid_text, "items"}},
          {%{"toc-count" => "1", "toc-0-anchor" => ["bad"]}, {:invalid_text, "items"}}
        ] do
      assert {:error, ^reason} = Blocks.validate_block_patch(toc, params)
    end

    assert {:error, {:invalid_text, "detail"}} =
             Blocks.validate_block_patch(progress, %{"detail" => %{"value" => "total"}})

    assert {:error, {:invalid_text, "rows"}} =
             Blocks.validate_block_patch(progress, %{
               "criterion-count" => "1",
               "criterion-0-label" => ["bad"]
             })
  end

  test "binary form values preserve malformed authored text and checkbox legacy shapes" do
    toc = %{
      "type" => "toc",
      "numbered" => %{"legacy" => true},
      "sticky" => "true",
      "items" => [%{"text" => %{"legacy" => "text"}, "level" => 1, "anchor" => ["old"]}]
    }

    assert {:ok, %{}} =
             Blocks.validate_block_patch(toc, %{
               "numbered" => "false",
               "sticky" => "false",
               "toc-count" => "1",
               "toc-0-text" => "",
               "toc-0-anchor" => ""
             })

    progress = %{
      "type" => "criteria-progress",
      "detail" => %{"legacy" => "detail"},
      "rows" => [%{"label" => ["old"], "met" => 0, "total" => 1}]
    }

    assert {:ok, %{}} =
             Blocks.validate_block_patch(progress, %{
               "detail" => "",
               "criterion-count" => "1",
               "criterion-0-label" => ""
             })
  end

  test "toc and criteria progress have add-menu defaults" do
    assert Blocks.default_block("toc", "toc-id") == %{
             "id" => "toc-id",
             "type" => "toc",
             "items" => [],
             "depth" => 2,
             "numbered" => false,
             "sticky" => false
           }

    assert Blocks.default_block("criteria-progress", "progress-id") == %{
             "id" => "progress-id",
             "type" => "criteria-progress",
             "rows" => [],
             "detail" => "rows"
           }

    html = render_component(&PaperEditor.paper_block_editor/1, %{slug: "new", blocks: []})
    assert html =~ ~s(<option value="toc">Table of contents</option>)
    assert html =~ ~s(<option value="criteria-progress">Criteria progress</option>)
  end
end
