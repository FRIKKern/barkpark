defmodule BarkparkWeb.Studio.TechnicalBlockPaintedCopyTest do
  # task-bbfdcf4c80b8300d long tail: a footnote's painted notes edit where they
  # read. The preview keeps the reader HTML byte-for-byte and names, per painted
  # note, the panel field it writes (BarkparkPaperPaintedCopy hook).
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Barkpark.PortableDoc.Render
  alias BarkparkWeb.Studio.StudioLive.Components.TechnicalBlockEditor

  defp preview(block) do
    html =
      render_component(&TechnicalBlockEditor.technical_block_editor/1,
        block: block,
        id: block["id"]
      )

    {html,
     html
     |> LazyHTML.from_fragment()
     |> LazyHTML.query(~s([data-test-id="paper-technical-preview"]))}
  end

  test "a footnote preview wires each painted note to its panel field, reader HTML unchanged" do
    block = %{
      "id" => "fn",
      "type" => "footnote",
      "notes" => [
        %{"id" => "a", "text" => "First."},
        %{"id" => "b", "text" => ""},
        "legacy",
        %{"id" => "c", "text" => "Third."}
      ]
    }

    {html, el} = preview(block)
    assert html =~ Render.render_block(block, %{style: :article})
    assert LazyHTML.attribute(el, "phx-hook") == ["BarkparkPaperPaintedCopy"]
    assert LazyHTML.attribute(el, "id") == ["technical-preview-fn"]
    assert LazyHTML.attribute(el, "data-painted-copy-form") == ["technical-block-form-fn"]

    # Only the notes the reader paints (map, non-empty text) are named, in order,
    # so painted row i always writes the stored note it shows.
    assert LazyHTML.attribute(el, "data-painted-copy-names") == ["note-0-text,note-3-text"]
    assert el |> LazyHTML.query("li") |> Enum.count() == 2

    form = html |> LazyHTML.from_fragment() |> LazyHTML.query("form#technical-block-form-fn")

    for name <- ~w(note-0-text note-3-text) do
      assert form |> LazyHTML.query(~s(textarea[name="#{name}"])) |> Enum.count() == 1
    end
  end

  test "criteria-progress wires each painted row label to its panel field" do
    block = %{
      "id" => "cp",
      "type" => "criteria-progress",
      "rows" => [
        %{"label" => "Survey", "met" => 2, "total" => 5},
        "legacy",
        %{"label" => " padded ", "met" => 1, "total" => 1},
        %{"label" => "File tasks", "met" => 5, "total" => 5}
      ]
    }

    attrs = TechnicalBlockEditor.painted_copy_attrs(block, "cp")
    assert attrs["phx-hook"] == "BarkparkPaperPaintedCopy"
    assert attrs["data-painted-copy-form"] == "criteria-progress-form-cp"

    # One name per painted row (map rows only); a label the reader repaints
    # trimmed stays read-only (empty name) so an edit can never drop its spaces.
    assert attrs["data-painted-copy-names"] == "criterion-0-label,,criterion-3-label"

    painted = Render.render_block(block, %{style: :article})

    assert painted
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(attrs["data-painted-copy"])
           |> Enum.count() == 3

    assert TechnicalBlockEditor.painted_copy_attrs(Map.put(block, "detail", "total"), "cp") == %{},
           "the aggregate Total row is derived, never wired"
  end

  test "api-endpoint wires the method, path and param cells it paints verbatim" do
    block = %{
      "id" => "ae",
      "type" => "api-endpoint",
      "method" => "POST",
      "path" => "/v1/data/mutate",
      "params" => [
        %{"name" => "dataset", "in" => "path", "type" => "string", "required" => true},
        "legacy",
        %{"name" => "dry", "in" => "", "type" => "boolean"}
      ]
    }

    attrs = TechnicalBlockEditor.painted_copy_attrs(block, "ae")
    assert attrs["data-painted-copy-form"] == "api-endpoint-form-ae"

    # Document order: method, path, then Name / In / Type / Required per map
    # param. The derived Required cell and an empty stored cell stay read-only.
    assert attrs["data-painted-copy-names"] ==
             "method,path,param-0-name,param-0-in,param-0-type,,param-2-name,,param-2-type,"

    painted = Render.render_block(block, %{style: :article})

    assert painted
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(attrs["data-painted-copy"])
           |> Enum.count() == 10

    lower = TechnicalBlockEditor.painted_copy_attrs(Map.put(block, "method", "post"), "ae")

    assert lower["data-painted-copy-names"] |> String.split(",") |> hd() == "",
           "a method the reader upcases is never written back from its painted form"
  end

  # r2b census: route caption, gauge-list text, bar labels and code tabs.
  defp painted_count(block, selector) do
    block
    |> Render.render_block(%{style: :article})
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end

  test "route wires its painted caption; the joined meta line stays panel-edited" do
    block = %{
      "id" => "r",
      "type" => "route",
      "polyline" => "}ujlJgxgcAyPqOgO~JsLc[wF{aAdJ{[hSeE~MzTbInh@aB~e@",
      "sport" => "sykling",
      "caption" => "Testrunden"
    }

    attrs = TechnicalBlockEditor.painted_copy_attrs(block, "r")
    assert attrs["data-painted-copy-form"] == "route-form-r"
    assert attrs["data-painted-copy-names"] == "caption"
    assert painted_count(block, attrs["data-painted-copy"]) == 1

    assert TechnicalBlockEditor.painted_copy_attrs(Map.put(block, "caption", " padded "), "r") ==
             %{}

    assert TechnicalBlockEditor.painted_copy_attrs(Map.delete(block, "caption"), "r") == %{}
  end

  test "gauge-list wires title, row labels and notes in document order (share mode only)" do
    block = %{
      "id" => "g",
      "type" => "gauge-list",
      "title" => "Coverage by surface",
      "rows" => [
        %{"label" => "Elixir", "note" => "source of truth", "value" => 2},
        %{"label" => " Go ", "value" => 1},
        %{"label" => "JS", "value" => 1, "note" => ""}
      ]
    }

    attrs = TechnicalBlockEditor.painted_copy_attrs(block, "g")
    assert attrs["data-painted-copy-form"] == "gauge-list-form-g"

    assert attrs["data-painted-copy-names"] ==
             "title,gauge-0-label,gauge-0-note,,gauge-2-label"

    assert painted_count(block, attrs["data-painted-copy"]) == 5

    untitled = TechnicalBlockEditor.painted_copy_attrs(Map.delete(block, "title"), "g")
    assert untitled["data-painted-copy-names"] == "gauge-0-label,gauge-0-note,,gauge-2-label"
    assert painted_count(Map.delete(block, "title"), untitled["data-painted-copy"]) == 4

    assert TechnicalBlockEditor.painted_copy_attrs(%{block | "rows" => ["legacy"]}, "g") == %{}

    assert TechnicalBlockEditor.painted_copy_attrs(
             Map.merge(block, %{"mode" => "count", "snapshot" => []}),
             "g"
           ) == %{},
           "count mode paints derived buckets, never wired"
  end

  test "bar-chart wires each painted bar label; values stay in the panel" do
    block = %{
      "id" => "b",
      "type" => "bar-chart",
      "values" => true,
      "bars" => [%{"label" => "paragraph", "value" => 40}, %{"label" => "heading", "value" => 25}]
    }

    attrs = TechnicalBlockEditor.painted_copy_attrs(block, "b")
    assert attrs["data-painted-copy-form"] == "bar-chart-form-b"
    assert attrs["data-painted-copy-names"] == "bar-0-label,bar-1-label"
    assert painted_count(block, attrs["data-painted-copy"]) == 2
    assert TechnicalBlockEditor.painted_copy_attrs(%{block | "bars" => []}, "b") == %{}
  end

  test "code-tabs wires tab labels and each code panel (multiline) to their panel fields" do
    block = %{
      "id" => "ct",
      "type" => "code-tabs",
      "tabs" => [
        %{"label" => "JS", "language" => "js", "value" => "console.log(1)"},
        %{"label" => "Go", "language" => "go", "code" => "fmt.Println(1)\nreturn"}
      ]
    }

    {html, el} = preview(block)
    assert html =~ Render.render_block(block, %{style: :article})
    assert LazyHTML.attribute(el, "phx-hook") == ["BarkparkPaperPaintedCopy"]
    assert LazyHTML.attribute(el, "data-painted-copy-form") == ["technical-block-form-ct"]

    assert LazyHTML.attribute(el, "data-painted-copy-names") ==
             ["tab-0-label,tab-1-label,tab-0-value,tab-1-value"]

    assert LazyHTML.attribute(el, "data-painted-copy-multiline") == [".bp-code-tabs__panel > pre"]
    [selector] = LazyHTML.attribute(el, "data-painted-copy")
    assert painted_count(block, selector) == 4

    form = html |> LazyHTML.from_fragment() |> LazyHTML.query("form#technical-block-form-ct")

    for name <- ~w(tab-0-label tab-1-label tab-0-value tab-1-value) do
      assert form |> LazyHTML.query(~s([name="#{name}"])) |> Enum.count() == 1, name
    end
  end

  test "tabs wires each section's painted label to its panel field; a placeholder label never" do
    block = %{
      "id" => "tb",
      "type" => "tabs",
      "tabs" => [
        %{"id" => "p1", "label" => "macOS", "blocks" => []},
        %{"id" => "p2", "label" => " ", "blocks" => []},
        %{"id" => "p3", "label" => "Linux", "blocks" => []}
      ]
    }

    html =
      render_component(&BarkparkWeb.Studio.StudioLive.Components.PaperEditor.paper_block_fields/1,
        block: block,
        root_slug: "paper",
        canvas_enabled: true,
        paper_rev: 1
      )

    tree = LazyHTML.from_fragment(html)
    preview = LazyHTML.query(tree, "[data-test-id='paper-tabs-preview']")
    assert LazyHTML.attribute(preview, "phx-hook") == ["BarkparkPaperPaintedCopy"]
    assert LazyHTML.attribute(preview, "data-painted-copy-form") == ["tabs-form-tb"]

    assert LazyHTML.attribute(preview, "data-painted-copy-names") == [
             "panel-0-label,,panel-2-label"
           ]

    # The painted label is exactly the stored label (no template whitespace), so
    # copying the host's text into the field writes back what is stored.
    labels = preview |> LazyHTML.query(".bp-tabs__label") |> Enum.map(&LazyHTML.text/1)
    assert labels == ["macOS", "Tab 2", "Linux"]

    form = LazyHTML.query(tree, "form#tabs-form-tb")

    for name <- ~w(panel-0-label panel-2-label) do
      assert form |> LazyHTML.query(~s([name="#{name}"])) |> Enum.count() == 1, name
    end
  end

  test "form wires prompts, rationales and single/multi options; derived choices never" do
    block = %{
      "id" => "fm",
      "type" => "form",
      "kind" => "questionnaire",
      "questions" => [
        %{
          "id" => "q1",
          "prompt" => "Which surface?",
          "rationale" => "Steers polish.",
          "recommendation" => "reader",
          "type" => "single",
          "options" => ["reader", "studio"]
        },
        %{"id" => "q2", "prompt" => "Ship it?", "type" => "yesno"},
        %{
          "id" => "q3",
          "prompt" => "Rate it",
          "type" => "scale",
          "scale" => %{"min" => 1, "max" => 3}
        },
        %{"id" => "q4", "prompt" => "Anything else?", "type" => "text"}
      ]
    }

    attrs = TechnicalBlockEditor.painted_copy_attrs(block, "fm")
    assert attrs["data-painted-copy-form"] == "form-editor-fm"

    assert attrs["data-painted-copy-names"] ==
             "question-0-prompt,question-0-rationale,,question-0-option-0,question-0-option-1," <>
               "question-1-prompt,,," <>
               "question-2-prompt,,,," <>
               "question-3-prompt"

    # the browser selector is :scope-anchored; the same rows without :scope
    selector = String.replace(attrs["data-painted-copy"], ":scope > ", "")
    names = String.split(attrs["data-painted-copy-names"], ",")
    assert painted_count(block, selector) == length(names)

    html =
      render_component(&BarkparkWeb.Studio.StudioLive.Components.PaperEditor.paper_block_fields/1,
        block: block,
        root_slug: "paper",
        canvas_enabled: true,
        paper_rev: 1
      )

    tree = LazyHTML.from_fragment(html)
    preview = LazyHTML.query(tree, "[data-test-id='paper-form-preview']")
    assert LazyHTML.attribute(preview, "phx-hook") == ["BarkparkPaperPaintedCopy"]
    form = LazyHTML.query(tree, "form#form-editor-fm")

    for name <- Enum.reject(names, &(&1 == "")) do
      assert form |> LazyHTML.query(~s([name="#{name}"])) |> Enum.count() == 1, name
    end
  end

  test "a code-tabs Configure toggle rests above the block, off the tab strip" do
    {_html, _el} =
      preview(%{
        "id" => "ct2",
        "type" => "code-tabs",
        "tabs" => [%{"label" => "JS", "value" => "x"}]
      })

    html =
      render_component(&TechnicalBlockEditor.technical_block_editor/1,
        block: %{
          "id" => "ct2",
          "type" => "code-tabs",
          "tabs" => [%{"label" => "JS", "value" => "x"}]
        },
        id: "ct2"
      )

    assert html =~
             ~s(class="bp-paper-contextual-controls bp-paper-contextual-controls--code-tabs")

    css =
      File.read!(Path.expand("../../../priv/static/assets/bp-paper-editor-shell.css", __DIR__))

    assert css =~
             ".bp-paper-contextual-controls.bp-paper-contextual-controls--code-tabs:not([open])"
  end

  test "other technical types and a footnote with nothing painted get no wiring" do
    for block <- [
          %{"id" => "d", "type" => "diff", "diff" => "+x"},
          %{"id" => "t", "type" => "filetree", "text" => "a/"},
          %{"id" => "e", "type" => "footnote", "notes" => [%{"text" => ""}]},
          %{"id" => "m", "type" => "footnote", "notes" => "not a list"}
        ] do
      {_html, el} = preview(block)
      assert LazyHTML.attribute(el, "phx-hook") == [], "#{block["id"]} must not be wired"
    end
  end
end
