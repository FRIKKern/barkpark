defmodule BarkparkWeb.Studio.PaperEditor.FigureEditorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Figures
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
    assert html =~ ~s(class="bp-paper-edit-form bp-paper-figure-caption-form")
    assert html =~ ~s(class="bp-paper-inline-text bp-paper-figure-caption-input")
    assert html =~ ~s(phx-hook="BarkparkPaperAutoSize")
    assert html =~ ~s(aria-label="Figure caption")
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

  test "an image child rests as the exact reader image with an accessible picker fallback" do
    child = %{
      "id" => "image-child",
      "type" => "image",
      "src" => "/media/files/figure.jpg",
      "alt" => "A trail map",
      "width" => 960,
      "height" => 540,
      "opaque" => %{"assetId" => "asset-1"}
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: figure(child),
        dataset: "production",
        scope_prefix: "/w/default/p/default",
        api_token_raw: "writer-token",
        picker_browse: true
      )

    tree = LazyHTML.from_fragment(html)
    preview = LazyHTML.query(tree, "[data-test-id='paper-figure-image-preview']")
    trigger = LazyHTML.query(tree, "[data-test-id='paper-figure-image-edit-trigger']")
    picker = LazyHTML.query(tree, "[data-test-id='paper-figure-image-picker']")
    frame = LazyHTML.query(tree, "figure.bp-paper-figure-editor-frame")

    reader_image = Render.render_block(child, %{style: :article})
    assert reader_image =~ ~s(data-bp-lightboxable="true")
    assert html =~ String.replace(reader_image, ~s( data-bp-lightboxable="true"), "")
    refute html =~ ~s(data-bp-lightboxable="true")
    assert LazyHTML.attribute(preview, "data-figure-id") == ["figure"]
    assert LazyHTML.attribute(preview, "data-child-id") == ["image-child"]
    assert LazyHTML.attribute(preview, "phx-hook") == ["BarkparkFigureImageBridge"]
    assert LazyHTML.attribute(preview, "data-block-id") == ["image-child"]
    assert LazyHTML.attribute(preview, "data-image-src") == ["/media/files/figure.jpg"]
    assert LazyHTML.attribute(trigger, "type") == ["button"]
    assert LazyHTML.attribute(trigger, "role") == []
    assert LazyHTML.attribute(trigger, "tabindex") == []
    assert LazyHTML.attribute(trigger, "aria-label") == ["Replace figure image: A trail map"]
    assert LazyHTML.attribute(trigger, "aria-haspopup") == ["dialog"]
    assert LazyHTML.to_html(trigger) =~ ~s(class="bp-paper-figure-image-trigger")
    assert LazyHTML.to_html(trigger) =~ ~s(></button>)
    assert Enum.empty?(LazyHTML.query(trigger, "img"))

    assert LazyHTML.attribute(
             LazyHTML.query(preview, ".bp-paper-figure-image-paint"),
             "class"
           ) == ["bp-paper-figure-image-paint"]

    assert LazyHTML.attribute(picker, "open") == []
    assert html =~ ~s(data-test-id="paper-block-image-picker")
    assert html =~ ~s(data-paper-figure-image-picker)
    assert html =~ ~s(value="/media/files/figure.jpg")
    assert html =~ ~s(dataset="production")
    assert html =~ ~s(scope-prefix="/w/default/p/default")
    assert html =~ ~s(data-token="writer-token")

    assert LazyHTML.attribute(frame, "style") == [
             "margin:var(--bp-air-figure, 1.6rem) 0 0;margin-inline:var(--bp-evidence-pull, 0px);width:var(--bp-evidence-width, 100%);box-sizing:border-box;overflow-x:visible"
           ]
  end

  test "an image child stays a passive exact reader image when media browsing is unavailable" do
    child = %{
      "id" => "image-child",
      "type" => "image",
      "src" => "/media/files/figure.jpg",
      "alt" => "A trail map"
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: figure(child),
        picker_browse: false
      )

    tree = LazyHTML.from_fragment(html)
    preview = LazyHTML.query(tree, "[data-test-id='paper-figure-image-preview']")
    trigger = LazyHTML.query(tree, "[data-test-id='paper-figure-image-edit-trigger']")

    reader_image = Render.render_block(child, %{style: :article})
    assert reader_image =~ ~s(data-bp-lightboxable="true")
    assert html =~ reader_image
    assert LazyHTML.attribute(preview, "phx-hook") == []
    assert Enum.empty?(trigger)
    refute html =~ ~s(data-test-id="paper-figure-image-picker")
    refute html =~ ~s(data-test-id="paper-block-image-picker")
  end

  test "a whitespace-only image source uses the visible empty-image recovery state" do
    child = %{
      "id" => "image-child",
      "type" => "image",
      "src" => " \n\t ",
      "alt" => "Missing trail map"
    }

    html =
      render_component(&PaperEditor.paper_block_fields/1,
        block: figure(child),
        picker_browse: true
      )

    tree = LazyHTML.from_fragment(html)
    preview = LazyHTML.query(tree, "[data-test-id='paper-figure-image-preview']")
    picker = LazyHTML.query(tree, "[data-test-id='paper-block-image-picker']")

    assert LazyHTML.attribute(preview, "data-image-src") == [""]
    assert LazyHTML.attribute(picker, "value") == [""]
    assert Enum.empty?(LazyHTML.query(preview, "img"))
    assert html =~ ~s(data-test-id="paper-figure-image-picker")
  end

  test "an empty caption keeps one stable textarea and exposes a zero-flow focus control" do
    block = figure(paragraph("child", "Inside")) |> Map.put("caption", "")
    html = render_component(&PaperEditor.paper_block_fields/1, block: block)
    tree = LazyHTML.from_fragment(html)
    caption = LazyHTML.query(tree, "figcaption.bp-figcaption")
    add = LazyHTML.query(tree, "[data-paper-figure-caption-add]")
    textarea = LazyHTML.query(tree, "#figure-caption-figure")

    assert LazyHTML.attribute(caption, "data-paper-figure-caption-empty") == ["true"]
    assert LazyHTML.attribute(add, "type") == ["button"]
    assert LazyHTML.text(add) == "Add caption"
    assert LazyHTML.attribute(textarea, "name") == ["caption"]
    assert LazyHTML.attribute(textarea, "phx-hook") == ["BarkparkPaperAutoSize"]
    assert LazyHTML.text(textarea) == ""

    assert LazyHTML.attribute(add, "phx-click") == [
             ~s([["focus",{"to":"#figure-caption-figure"}]])
           ]
  end

  test "a caption keeps canonical reader paint and a stable focus-revealed textarea across an ACK" do
    authored = "Figure 2. First & <line>\nSecond line"
    block = figure(paragraph("child", "Inside")) |> Map.put("caption", authored)
    html = render_component(&PaperEditor.paper_block_fields/1, block: block)
    tree = LazyHTML.from_fragment(html)
    caption = LazyHTML.query(tree, "figcaption.bp-figcaption")
    paint = LazyHTML.query(tree, "[data-paper-figure-caption-paint]")
    textarea = LazyHTML.query(tree, "#figure-caption-figure")

    assert LazyHTML.attribute(caption, "data-paper-figure-caption-empty") == []
    assert LazyHTML.attribute(paint, "type") == ["button"]
    assert LazyHTML.attribute(paint, "aria-label") == ["Edit figure caption: " <> authored]
    assert LazyHTML.attribute(paint, "aria-controls") == ["figure-caption-figure"]

    assert LazyHTML.attribute(paint, "phx-click") == [
             ~s([["focus",{"to":"#figure-caption-figure"}]])
           ]

    assert html =~ Figures.figcaption_inner(authored)
    assert LazyHTML.text(textarea) == authored
    refute html =~ "<line>"
    assert html =~ "&amp;"
    assert html =~ "&lt;line&gt;"
    refute html =~ ~s(data-paper-figure-caption-add)

    acknowledged =
      render_component(&PaperEditor.paper_block_fields/1,
        block: Map.put(block, "caption", "Figure 2. Acknowledged")
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(LazyHTML.query(acknowledged, "form"), "id") ==
             ["figure-form-figure"]

    assert LazyHTML.attribute(LazyHTML.query(acknowledged, "textarea"), "id") ==
             ["figure-caption-figure"]

    assert LazyHTML.attribute(
             LazyHTML.query(acknowledged, "[data-paper-figure-caption-paint]"),
             "id"
           ) == ["figure-caption-paint-figure"]

    assert LazyHTML.text(LazyHTML.query(acknowledged, "[data-paper-figure-caption-paint]")) ==
             "Figure 2. Acknowledged"
  end

  test "caption paint follows reader stringification for scalar and malformed source values" do
    numeric = figure(paragraph("child", "Inside")) |> Map.put("caption", 42.5)
    numeric_html = render_component(&PaperEditor.paper_block_fields/1, block: numeric)
    numeric_tree = LazyHTML.from_fragment(numeric_html)

    assert LazyHTML.text(LazyHTML.query(numeric_tree, "[data-paper-figure-caption-paint]")) ==
             "42.5"

    assert LazyHTML.text(LazyHTML.query(numeric_tree, "#figure-caption-figure")) == "42.5"

    for value <- [nil, %{"opaque" => true}, ["opaque"]] do
      block = figure(paragraph("child", "Inside")) |> Map.put("caption", value)
      html = render_component(&PaperEditor.paper_block_fields/1, block: block)

      tree = LazyHTML.from_fragment(html)

      assert LazyHTML.attribute(
               LazyHTML.query(tree, "figcaption"),
               "data-paper-figure-caption-empty"
             ) == ["true"]

      assert Enum.empty?(LazyHTML.query(tree, "[data-paper-figure-caption-paint]"))
      assert LazyHTML.text(LazyHTML.query(tree, "textarea")) == ""
    end
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
