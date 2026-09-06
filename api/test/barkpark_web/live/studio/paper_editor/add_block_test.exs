defmodule BarkparkWeb.Studio.PaperEditor.AddBlockTest do
  @moduledoc """
  Creation coverage for every type currently offered by the Add block menu.

  The menu offers a subset of the canonical portable-doc inventory. Each
  choice resolves to default_block/2 and is appended through the
  canonical paper-add-block → paper_op → Content.apply_paper_block_op pipeline,
  which renders the new block (compose_block must accept it) and persists. These
  assertions prove creation and mounting, not every editing interaction or
  support for canonical types absent from the menu.

  `@addable_block_types` + the per-type `addable_block_valid?/1` invariant are
  section-local. The shared base paper + `open_editor` come from
  `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  # Every type the add-block menu offers (the optgroup list, in order). The
  # per-type invariant (so a degraded default surfaces as a failure) lives in
  # `addable_block_valid?/1` below — module attributes cannot hold closures.
  @addable_block_types ~w(
    paragraph heading list callout code blockquote divider section steps tabs
    eyebrow byline ingress pullquote
    action card table terminal stage diagram figure equation route toc criteria-progress gauge-list
    diff filetree footnote code-tabs api-endpoint form questionnaire
    field-string field-slug field-text field-boolean field-select field-datetime field-color field-number
    field-image field-reference video
    columns composite arrayOf codelist localizedText
  )

  test "the rendered Add menu exactly matches the creation regression inventory", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    offered =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-test-id="paper-add-block"] select[name="block-type"] option))
      |> LazyHTML.attribute("value")

    assert offered == @addable_block_types
    assert Enum.uniq(offered) == offered

    assert MapSet.subset?(
             MapSet.new(offered),
             MapSet.new(Barkpark.PortableDoc.Tiers.known_types())
           )
  end

  # The per-type invariant the freshly-built default block must satisfy.
  defp addable_block_valid?(%{"type" => "paragraph"}), do: true
  defp addable_block_valid?(%{"type" => "heading", "level" => 2}), do: true
  defp addable_block_valid?(%{"type" => "list", "ordered" => false}), do: true
  defp addable_block_valid?(%{"type" => "callout", "tone" => "info"}), do: true
  defp addable_block_valid?(%{"type" => "code"}), do: true
  defp addable_block_valid?(%{"type" => "blockquote", "content" => []}), do: true
  defp addable_block_valid?(%{"type" => "divider"}), do: true
  defp addable_block_valid?(%{"type" => "section", "blocks" => b}) when is_list(b), do: true
  # article-chrome blocks (barkpark-54kh) — empty default shapes matching
  # Render.compose_block/2 (flat text / items list / inline content array).
  defp addable_block_valid?(%{"type" => "eyebrow", "text" => ""}), do: true
  defp addable_block_valid?(%{"type" => "byline", "items" => []}), do: true
  defp addable_block_valid?(%{"type" => "ingress", "content" => []}), do: true
  defp addable_block_valid?(%{"type" => "pullquote", "content" => []}), do: true
  # diagram (barkpark-woxx) — flat {source, caption} default, both "" (the exact
  # shape Render.Compose.compose_block/2's "diagram" clause reads).
  defp addable_block_valid?(%{"type" => "diagram", "source" => "", "caption" => ""}), do: true
  defp addable_block_valid?(%{"type" => "action", "href" => "", "label" => ""}), do: true

  defp addable_block_valid?(%{"type" => "table"} = table),
    do: match?({:ok, _}, Barkpark.PortableDoc.TableEditing.project(table))

  defp addable_block_valid?(%{"type" => "terminal", "children" => []} = terminal),
    do: not Map.has_key?(terminal, "blocks")

  defp addable_block_valid?(%{
         "type" => "card",
         "slots" => %{
           "title" => [%{"type" => "heading", "text" => "New card"}],
           "body" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => ""}]}]
         }
       }),
       do: true

  defp addable_block_valid?(%{"type" => "figure", "child" => %{"type" => "paragraph"}}),
    do: true

  defp addable_block_valid?(%{"type" => "equation", "tex" => "", "display" => true}), do: true
  defp addable_block_valid?(%{"type" => "route", "polyline" => "", "caption" => ""}), do: true
  defp addable_block_valid?(%{"type" => "toc", "items" => [], "depth" => 2}), do: true
  defp addable_block_valid?(%{"type" => "criteria-progress", "rows" => []}), do: true

  defp addable_block_valid?(%{
         "type" => "gauge-list",
         "mode" => "share",
         "rows" => [%{"value" => 0}]
       }),
       do: true

  defp addable_block_valid?(%{
         "type" => "steps",
         "steps" => [%{"title" => "Step 1", "blocks" => [%{"type" => "paragraph"}]}]
       }),
       do: true

  defp addable_block_valid?(%{
         "type" => "tabs",
         "tabs" => [%{"label" => "Tab 1", "blocks" => [%{"type" => "paragraph"}]}]
       }),
       do: true

  defp addable_block_valid?(%{
         "type" => type,
         "questions" => [%{"prompt" => "Question 1", "type" => "text"}]
       })
       when type in ["form", "questionnaire"],
       do: true

  defp addable_block_valid?(%{"type" => "diff", "diff" => "", "file" => ""}), do: true
  defp addable_block_valid?(%{"type" => "filetree", "text" => "", "legend" => ""}), do: true
  defp addable_block_valid?(%{"type" => "footnote", "notes" => []}), do: true
  defp addable_block_valid?(%{"type" => "code-tabs", "tabs" => [], "syncKey" => ""}), do: true

  defp addable_block_valid?(%{
         "type" => "api-endpoint",
         "method" => "",
         "path" => "",
         "params" => []
       }),
       do: true

  defp addable_block_valid?(%{"type" => "video", "src" => "", "poster" => "", "captions" => []}),
    do: true

  defp addable_block_valid?(%{"type" => "columns", "columns" => [[], []]}), do: true
  defp addable_block_valid?(%{"type" => "field-string", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-slug", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-text", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-boolean", "value" => false}), do: true
  defp addable_block_valid?(%{"type" => "field-datetime", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-color", "value" => "#000000"}), do: true
  defp addable_block_valid?(%{"type" => "field-number", "value" => nil}), do: true

  defp addable_block_valid?(%{"type" => "field-select", "options" => o}) when length(o) == 2,
    do: true

  defp addable_block_valid?(%{"type" => "field-reference", "refType" => _}), do: true
  defp addable_block_valid?(%{"type" => "field-image", "value" => ""}), do: true

  defp addable_block_valid?(%{"type" => "composite", "fields" => f, "value" => v})
       when is_list(f) and is_map(v),
       do: true

  defp addable_block_valid?(%{"type" => "arrayOf", "value" => [], "of" => of}) when is_map(of),
    do: true

  defp addable_block_valid?(%{"type" => "codelist", "codelistId" => _}), do: true

  defp addable_block_valid?(%{"type" => "localizedText", "languages" => ["en"], "value" => v})
       when is_map(v),
       do: true

  defp addable_block_valid?(%{"type" => "stage", "title" => "New stage"}), do: true
  defp addable_block_valid?(_), do: false

  for type <- @addable_block_types do
    test "adding a #{type} block via the add-block UI appends a valid block", %{conn: conn} do
      type = unquote(type)

      {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
      open_editor(view)

      before_count = Content.paper_blocks(@slug, @dataset) |> length()

      view
      |> element(~s([data-test-id="paper-add-block"]))
      |> render_submit(wire_params(view, %{"block-type" => type}))

      blocks = Content.paper_blocks(@slug, @dataset)
      assert length(blocks) == before_count + 1

      last = List.last(blocks)
      assert last["type"] == type
      # Fresh immutable "b-" id, the per-type default shape, and it renders in
      # the editor (so compose_block accepted it during render_blocks).
      assert String.starts_with?(last["id"], "b-")

      assert addable_block_valid?(last),
             "default #{type} block did not satisfy its invariant: #{inspect(last)}"

      assert render(view) =~ ~s(data-edit-block-id="#{last["id"]}")
    end
  end

  defp wire_params(view, params) do
    Map.merge(params, %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => :sys.get_state(view.pid).socket.assigns.paper_rev
    })
  end
end
