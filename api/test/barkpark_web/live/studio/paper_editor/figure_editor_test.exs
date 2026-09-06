defmodule BarkparkWeb.Studio.PaperEditor.FigureEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Studio.StudioLive.Blocks
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.PaperCanvas

  @editor_shell_css Path.expand(
                      "../../../../../priv/static/assets/bp-paper-editor-shell.css",
                      __DIR__
                    )

  test "Figure is creatable with the canonical singular child shape" do
    html =
      render_component(&PaperEditor.paper_block_editor/1,
        slug: "paper",
        blocks: [],
        canvas_eligible: true
      )

    assert html =~ ~s(<option value="figure">Figure</option>)

    assert Blocks.default_block("figure", "figure") == %{
             "id" => "figure",
             "type" => "figure",
             "child" => %{
               "type" => "paragraph",
               "content" => [%{"type" => "text", "value" => ""}]
             }
           }
  end

  test "Figure is a contextual run boundary with a collision-safe child slug" do
    figure = figure(paragraph("child", "Inside"))

    refute PaperCanvas.canvas?(figure)
    assert PaperCanvas.partition_runs([figure]) == [{:block, figure}]

    refute PaperCanvas.figure_run_slug("paper", "a-b") ==
             PaperCanvas.figure_run_slug("paper-a", "b")

    assert String.starts_with?(PaperCanvas.figure_run_slug("paper", "figure"), "paper-figure-")
  end

  test "canvas-enabled Figure mounts exactly its singular child run with strict context" do
    child = paragraph("child", "Inside")

    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: figure(child),
        canvas_enabled: true,
        root_slug: "paper",
        doc_key: "production:paper:paper",
        paper_rev: 7
      )

    tree = LazyHTML.from_fragment(html)
    runs = LazyHTML.query(tree, "[data-test-id='paper-canvas-run']")
    assert LazyHTML.attribute(runs, "data-test-id") == ["paper-canvas-run"]
    assert LazyHTML.attribute(runs, "data-paper-container-kind") == ["figure"]
    assert LazyHTML.attribute(runs, "data-paper-container-id") == ["figure"]
    assert LazyHTML.attribute(runs, "data-paper-container-run") == ["0"]
    assert LazyHTML.attribute(runs, "data-paper-container-row-id") == []
    assert LazyHTML.attribute(runs, "data-canvas-blocks") == [Jason.encode!([child])]
    assert html =~ ~s(id="paper-canvas-#{PaperCanvas.figure_run_slug("paper", "figure")}-run-0")
    frame = LazyHTML.query(tree, "figure.bp-paper-figure-editor-frame")

    assert LazyHTML.attribute(frame, "style") == [
             "margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:auto"
           ]
  end

  test "Figure editing chrome expands to the same evidence band as the reader frame" do
    css = File.read!(@editor_shell_css)

    assert css =~
             ~r/\.bp-paper-edit-block\[data-block-type="figure"\]:has\(\.bp-paper-figure-editor-frame\)\s*\{[^}]*margin-inline:\s*var\(--bp-evidence-pull,\s*0px\);[^}]*width:\s*var\(--bp-evidence-width,\s*100%\);/s
  end

  test "generic Beta recursively edits the child and keeps caption as a sibling form" do
    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: figure(paragraph("child", "Inside")),
        canvas_enabled: false
      )

    tree = LazyHTML.from_fragment(html)
    assert html =~ ~s(data-test-id="paper-figure-editor")
    assert html =~ ~s(id="paper-ed-child")
    assert html =~ ~s(id="figure-form-figure")
    assert Enum.empty?(LazyHTML.query(tree, "form form"))
    refute html =~ ~s(data-test-id="paper-canvas-run")
  end

  test "a boundary child recursively keeps its own editor beside the caption form" do
    child = %{"id" => "survey", "type" => "form", "questions" => []}
    html = render_component(&PaperEditor.paper_block_fields/1, block: figure(child))
    tree = LazyHTML.from_fragment(html)

    assert html =~ ~s(data-test-id="paper-form-editor")
    assert html =~ ~s(data-test-id="paper-figure-caption-editor")
    assert Enum.empty?(LazyHTML.query(tree, "form form"))
  end

  test "missing, nil, scalar, and unstable children remain honest read-only previews" do
    for child <- [:missing, nil, "legacy", %{"id" => "  ", "type" => "paragraph"}] do
      block =
        if child == :missing,
          do: Map.delete(figure(paragraph("child", "Inside")), "child"),
          else: Map.put(figure(paragraph("child", "Inside")), "child", child)

      html = render_component(&PaperEditor.paper_block_fields/1, block: block)
      assert html =~ ~s(data-test-id="paper-figure-editor")
      assert html =~ ~s(data-test-id="paper-figure-preview")
      assert html =~ "original content is preserved"
      refute html =~ ~s(data-test-id="paper-figure-caption-editor")
      refute html =~ ~s(data-test-id="paper-canvas-run")
      refute html =~ ~s(data-test-id="paper-block-editor-wc")
    end
  end

  test "caption patch is presence-aware, strict, and never carries the child" do
    child = paragraph("child", "Inside") |> Map.put("opaque", [1, 2])
    block = figure(child) |> Map.put("opaque", %{"outer" => true})

    assert {:ok, %{"caption" => "Changed"}} =
             Blocks.validate_block_patch(block, %{
               "caption" => "Changed",
               "child" => %{"id" => "attacker"}
             })

    assert Blocks.build_block_patch(block, %{"caption" => "Changed", "child" => []}) == %{
             "caption" => "Changed"
           }

    assert {:ok, %{}} = Blocks.validate_block_patch(block, %{})

    assert {:error, {:invalid_text, "caption"}} =
             Blocks.validate_block_patch(block, %{"caption" => %{}})

    refute Map.has_key?(Blocks.build_block_patch(block, %{"caption" => "Changed"}), "child")

    for original <- [Map.delete(block, "caption"), Map.put(block, "caption", nil)] do
      assert Blocks.build_block_patch(original, %{"caption" => ""}) == %{}
    end
  end

  test "typed lookup reaches only the singular Figure child" do
    child = paragraph("child", "Inside")
    block = figure(child)
    assert Blocks.find_paper_block([block], "child") == child
    assert Blocks.find_paper_block([Map.put(block, "child", [child])], "child") == nil
    assert Blocks.find_paper_block([Map.put(block, "type", "legacy")], "child") == nil
  end

  test "footer counts only reader-visible Figure child and caption copy" do
    block =
      figure(paragraph("child", "two child words"))
      |> Map.put("caption", "two caption words")
      |> Map.put("opaque", "excluded metadata words")

    html = render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: [block])

    footer =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-test-id='bp-paper-footer']")
      |> LazyHTML.text()

    assert footer =~ "6 words"
    assert footer =~ "1 blocks"
  end

  test "footer treats a malformed non-map child as opaque" do
    block = figure("excluded malformed child words") |> Map.put("caption", "visible caption")

    footer =
      render_component(&PaperEditor.paper_block_editor/1, slug: "paper", blocks: [block])
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-test-id='bp-paper-footer']")
      |> LazyHTML.text()

    assert footer =~ "2 words"
  end

  defp figure(child) do
    %{
      "id" => "figure",
      "type" => "figure",
      "caption" => "A caption",
      "child" => child
    }
  end

  defp paragraph(id, text) do
    %{
      "id" => id,
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => text}]
    }
  end
end
