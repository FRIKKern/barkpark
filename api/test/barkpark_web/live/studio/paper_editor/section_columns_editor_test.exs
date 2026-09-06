defmodule BarkparkWeb.Studio.PaperEditor.SectionColumnsEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render.SectionLayout
  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  @editor_shell_css Path.expand(
                      "../../../../../priv/static/assets/bp-paper-editor-shell.css",
                      __DIR__
                    )

  test "pure Section layout decisions preserve canonical parsing" do
    assert SectionLayout.grid(%{"layout" => %{"mode" => "grid", "tracks" => "3", "gap" => "sm"}}) ==
             %{style: "--bp-tracks:3;--bp-grid-gap:var(--bp-space-sm,0.8rem)"}

    assert SectionLayout.grid(%{"layout" => %{"mode" => "stack"}}) == nil
    assert SectionLayout.frame_class(%{"variant" => "wide"}) == "bp-section--wide"
    assert SectionLayout.frame_class(%{"variant" => "unknown"}) == nil

    assert SectionLayout.cell_style(%{"span" => "2", "order" => "-1"}) ==
             "grid-column:span 2;order:-1"

    assert SectionLayout.cell_style(%{"span" => "0", "order" => "bad"}) == nil
    refute SectionLayout.stack_rules?(%{"blocks" => [%{"type" => "heading"}]}, :article)
    assert SectionLayout.stack_rules?(%{"blocks" => [%{"type" => "heading"}]}, :email)
  end

  test "Section title patches distinguish omission, clearing, trimming, and invalid values" do
    section = %{
      "id" => "section",
      "type" => "section",
      "title" => "Existing",
      "layout" => %{"mode" => "grid"},
      "unknown" => %{"kept" => true},
      "blocks" => []
    }

    assert Blocks.build_block_patch(section, %{}) == %{}
    assert Blocks.build_block_patch(section, %{"title" => "   "}) == %{"title" => nil}

    assert Blocks.build_block_patch(section, %{"title" => "  Revised  "}) == %{
             "title" => "Revised"
           }

    assert Blocks.resolve_block_form([section], %{
             "block_id" => "section",
             "title" => "  Revised  "
           }) ==
             {:ok,
              %{
                "op" => "patch-block",
                "id" => "section",
                "patch" => %{"title" => "Revised"}
              }}

    assert Blocks.resolve_block_form([section], %{"block_id" => "section"}) ==
             {:ok, %{"op" => "patch-block", "id" => "section", "patch" => %{}}}

    assert Blocks.resolve_block_form([section], %{"block_id" => "section", "title" => %{}}) ==
             {:error, {:source_validation, :invalid_section_title}}

    html = render_fields(section)
    tree = LazyHTML.from_fragment(html)
    title = LazyHTML.query(tree, "form[name='section-config'] input[name='title']")

    assert Enum.count(LazyHTML.query(tree, "#section-controls-section")) == 1

    assert Enum.count(
             LazyHTML.query(
               tree,
               "#section-form-section[data-test-id='paper-section-config-editor']"
             )
           ) == 1

    assert LazyHTML.attribute(title, "value") == ["Existing"]
    assert Enum.count(title) == 1
  end

  test "Columns is addable and editor-only wide geometry follows reader evidence bands" do
    html = render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: [])
    css = File.read!(@editor_shell_css)

    assert html =~ ~s(<option value="columns">Columns</option>)

    assert css =~
             ~S|.bp-paper-edit-block[data-block-type="columns"]:has([data-paper-columns-editor-frame])|

    assert css =~
             ~S|.bp-paper-edit-block[data-block-type="section"]:has([data-paper-section-editor-frame].bp-section--wide)|

    assert css =~
             ~S|.bp-section__cell > .bp-paper-edit-wc:first-child .bp-paper-editor-body .ProseMirror > :first-child {
  margin-top: 0;
}|

    assert css =~ ".bp-paper-contextual-controls--section[open]"
    assert css =~ ".bp-paper-contextual-controls--section[open] > .bp-paper-contextual-panel"
  end

  test "stack Section keeps reader chrome and mounts maximal contextual canvas runs" do
    section = %{
      "id" => "section",
      "type" => "section",
      "title" => "Overview",
      "blocks" => [paragraph("one", "One"), paragraph("two", "Two")]
    }

    html = render_fields(section, canvas_enabled: true)
    tree = LazyHTML.from_fragment(html)

    assert html =~ ~s(data-test-id="paper-section-editor")
    assert html =~ "bp-paper-contextual-controls--section"
    assert html =~ ~s(data-paper-section-editor-frame)
    assert html =~ ~s(<hr class="bp-hr" style="border-top-width:1px")
    assert html =~ ~s(<span style="font-weight:bold">Overview</span>)
    assert Enum.count(LazyHTML.query(tree, "[data-test-id='paper-canvas-run']")) == 1

    assert LazyHTML.attribute(
             LazyHTML.query(tree, "[data-test-id='paper-canvas-run']"),
             "data-paper-container-kind"
           ) == ["section"]

    assert html =~ PaperCanvas.section_run_slug("paper", "section")
  end

  test "untitled stack Section opening with a heading omits both rules" do
    section = %{
      "id" => "section",
      "type" => "section",
      "blocks" => [%{"id" => "h", "type" => "heading", "level" => 2, "content" => []}]
    }

    html = render_fields(section, canvas_enabled: false)
    refute html =~ ~s(<hr class="bp-hr")
  end

  test "normal Section omits a class while fixed frame variants stay on the inner box" do
    normal = render_fields(%{"id" => "normal", "type" => "section", "blocks" => []})

    wide =
      render_fields(%{"id" => "wide", "type" => "section", "variant" => "wide", "blocks" => []})

    assert LazyHTML.attribute(
             LazyHTML.query(LazyHTML.from_fragment(normal), "[data-paper-section-editor-frame]"),
             "class"
           ) == []

    assert LazyHTML.attribute(
             LazyHTML.query(LazyHTML.from_fragment(wide), "[data-paper-section-editor-frame]"),
             "class"
           ) == ["bp-section--wide"]
  end

  test "grid Section keeps source cells, placement, recursive editors, and controls outside grid" do
    section = %{
      "id" => "section",
      "type" => "section",
      "title" => "Grid",
      "layout" => %{"mode" => "grid", "tracks" => 3, "gap" => "lg"},
      "blocks" => [
        paragraph("first", "First")
        |> Map.merge(%{"span" => 2, "order" => 9, "unknown" => "kept"}),
        paragraph("second", "Second") |> Map.put("order", -1)
      ]
    }

    html = render_fields(section, canvas_enabled: true)
    tree = LazyHTML.from_fragment(html)
    grid = LazyHTML.query(tree, ".bp-section__grid")

    assert LazyHTML.attribute(grid, "style") == [
             "--bp-tracks:3;--bp-grid-gap:var(--bp-space-lg,2.4rem)"
           ]

    assert LazyHTML.attribute(LazyHTML.query(grid, ".bp-section__cell"), "style") == [
             "grid-column:span 2;order:9",
             "order:-1"
           ]

    assert LazyHTML.attribute(
             LazyHTML.query(grid, "[data-test-id='paper-block-editor-wc']"),
             "id"
           ) == ["paper-ed-first", "paper-ed-second"]

    assert Enum.empty?(LazyHTML.query(grid, "form"))
    assert Enum.count(LazyHTML.query(tree, "form[name='section-config']")) == 1
    refute html =~ ~s(data-paper-container-kind="section")
    assert html =~ "first"
    assert html =~ "second"
  end

  test "Columns preserves source columns and mounts maximal runs with column context" do
    columns = %{
      "id" => "columns",
      "type" => "columns",
      "columns" => [
        [paragraph("left-a", "A"), paragraph("left-b", "B")],
        [paragraph("right", "R")]
      ]
    }

    html = render_fields(columns, canvas_enabled: true)
    tree = LazyHTML.from_fragment(html)
    frame = LazyHTML.query(tree, "[data-paper-columns-editor-frame]")
    runs = LazyHTML.query(frame, "[data-test-id='paper-canvas-run']")

    assert LazyHTML.attribute(frame, "class") == ["bp-cols"]
    assert LazyHTML.attribute(frame, "style") == ["--bp-cols:2"]

    assert LazyHTML.attribute(LazyHTML.query(frame, ".bp-cols__c"), "data-column-index") == [
             "0",
             "1"
           ]

    assert Enum.count(runs) == 2
    assert LazyHTML.attribute(runs, "data-paper-container-kind") == ["columns", "columns"]
    assert LazyHTML.attribute(runs, "data-paper-container-column-index") == ["0", "1"]
    assert html =~ PaperCanvas.columns_run_slug("paper", "columns", 0)
    assert html =~ PaperCanvas.columns_run_slug("paper", "columns", 1)
  end

  test "generic Beta recursively edits every canonical Columns child" do
    columns = %{
      "id" => "columns",
      "type" => "columns",
      "columns" => [[paragraph("left", "L")], [paragraph("right", "R")]]
    }

    html = render_fields(columns, canvas_enabled: false)
    assert html =~ ~s(id="paper-ed-left")
    assert html =~ ~s(id="paper-ed-right")
    refute html =~ ~s(data-test-id="paper-canvas-run")
  end

  test "malformed whole Columns remains read-only and unchanged" do
    duplicate_across_columns = [[paragraph("duplicate", "A")], [paragraph("duplicate", "B")]]

    nested_duplicate = [
      [
        %{
          "id" => "section",
          "type" => "section",
          "blocks" => [paragraph("nested-duplicate", "Nested")]
        }
      ],
      [%{"id" => "nested-duplicate", "type" => "form", "questions" => []}]
    ]

    for malformed <- [
          nil,
          "opaque",
          [[], %{"opaque" => true}],
          duplicate_across_columns,
          nested_duplicate
        ] do
      html = render_fields(%{"id" => "columns", "type" => "columns", "columns" => malformed})
      assert html =~ ~s(data-test-id="paper-columns-editor")
      assert html =~ "original content is preserved"
      refute html =~ ~s(data-paper-columns-editor-frame)
    end
  end

  test "malformed Section children remain read-only without mounting a partial run" do
    html = render_fields(%{"id" => "section", "type" => "section", "blocks" => ["opaque"]})
    assert html =~ "original content is preserved"
    refute html =~ ~s(data-paper-container-kind="section")
  end

  test "malformed Section fields remain read-only without unsafe preview rendering" do
    for malformed <- [
          %{"id" => "section", "type" => "section", "blocks" => nil},
          %{"id" => "section", "type" => "section", "blocks" => "opaque"},
          %{"id" => "section", "type" => "section", "blocks" => %{}},
          %{"id" => "section", "type" => "section", "title" => %{}, "blocks" => []},
          %{"id" => "section", "type" => "section", "title" => [], "blocks" => []}
        ] do
      html = render_fields(malformed)
      assert html =~ "original content is preserved"
      refute html =~ ~s(data-paper-section-editor-frame)
      refute html =~ ~s(data-test-id="paper-section-config-editor")
      refute html =~ ~s(data-paper-container-kind="section")
    end
  end

  test "whole-tree duplicate identities make nested Section and Columns editors read-only" do
    section = %{
      "id" => "section",
      "type" => "section",
      "blocks" => [%{"id" => "outside-section", "type" => "form", "questions" => []}]
    }

    section_html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: [%{"id" => "outside-section", "type" => "form", "questions" => []}, section]
      )

    assert section_html =~ ~s(data-test-id="paper-identity-readonly")
    assert section_html =~ "original content is preserved"
    refute section_html =~ ~s(data-test-id="paper-section-editor")
    refute section_html =~ ~s(data-paper-section-editor-frame)
    refute section_html =~ ~s(id="section-form-section")
    refute section_html =~ ~s(data-test-id="paper-form-editor")
    refute section_html =~ ~s(data-test-id="paper-add-block")
    refute section_html =~ ~s(data-test-id="paper-move-up")

    columns = %{
      "id" => "columns",
      "type" => "columns",
      "columns" => [[paragraph("outside-columns", "Nested")]]
    }

    columns_html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: [%{"id" => "outside-columns", "type" => "form", "questions" => []}, columns]
      )

    assert columns_html =~ ~s(data-test-id="paper-identity-readonly")
    assert columns_html =~ "original content is preserved"
    refute columns_html =~ ~s(data-test-id="paper-columns-editor")
    refute columns_html =~ ~s(data-paper-columns-editor-frame)
    refute columns_html =~ ~s(data-test-id="paper-form-editor")
    refute columns_html =~ ~s(data-test-id="paper-add-block")
    refute columns_html =~ ~s(data-test-id="paper-move-up")
  end

  test "identity-unsafe readonly mode does not render a second malformed Section shape" do
    blocks = [
      paragraph("duplicate", "Outside"),
      %{"id" => "section", "type" => "section", "blocks" => "opaque"},
      paragraph("duplicate", "Nested collision")
    ]

    html = render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: blocks)

    assert html =~ ~s(data-test-id="paper-identity-readonly")
    assert html =~ "original content is preserved"
    refute html =~ ~s(data-test-id="paper-section-editor")
    refute html =~ ~s(data-test-id="paper-add-block")
    refute html =~ ~s(data-test-id="paper-move-up")
  end

  test "context extraction preserves absent indexes, requires integer Columns indexes, and finds nested children" do
    assert Blocks.canvas_run_context(%{
             "container_kind" => "section",
             "container_id" => "section",
             "container_run_ids" => ["inside"]
           }) ==
             {:ok,
              %{
                container_kind: "section",
                container_id: "section",
                container_run_ids: ["inside"]
              }}

    assert Blocks.canvas_run_context(%{
             "container_kind" => "columns",
             "container_id" => "columns",
             "container_column_index" => 1,
             "container_run_ids" => ["right"]
           }) ==
             {:ok,
              %{
                container_kind: "columns",
                container_id: "columns",
                container_column_index: 1,
                container_run_ids: ["right"]
              }}

    assert Blocks.canvas_run_context(%{
             "container_kind" => "columns",
             "container_id" => "columns",
             "container_column_index" => "1",
             "container_run_ids" => ["right"]
           }) == {:error, :invalid_container_context}

    nested = %{"id" => "columns", "type" => "columns", "columns" => [[paragraph("left", "L")]]}
    assert Blocks.find_paper_block([nested], "left")["id"] == "left"
  end

  test "footer word count follows reader-visible Section and Columns descendants only" do
    blocks = [
      %{
        "id" => "section",
        "type" => "section",
        "title" => "Section title",
        "blocks" => [paragraph("inside", "three words here")]
      },
      %{
        "id" => "columns",
        "type" => "columns",
        "columns" => [[paragraph("left", "left words")], "opaque"]
      }
    ]

    html = render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: blocks)
    assert html =~ ">7 words<"
  end

  defp render_fields(block, opts) do
    render_component(
      &PaperEditor.paper_block_fields/1,
      [
        block: block,
        root_slug: "paper",
        doc_key: "production:paper:paper",
        paper_rev: 7
      ] ++ opts
    )
  end

  defp render_fields(block), do: render_fields(block, [])

  defp paragraph(id, text),
    do: %{"id" => id, "type" => "paragraph", "content" => [%{"type" => "text", "value" => text}]}
end
