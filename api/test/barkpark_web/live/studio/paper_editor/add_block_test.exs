defmodule BarkparkWeb.Studio.PaperEditor.AddBlockTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — P3.1: every block type is creatable.

  The add-block <select> offers every portable-doc block type (grouped by
  optgroup). Each choice resolves to default_block/2 and is appended through the
  canonical paper-add-block → paper_op → Content.apply_paper_block_op pipeline,
  which renders the new block (compose_block must accept it) and persists. These
  assertions prove the full round-trip for every type.

  `@addable_block_types` + the per-type `addable_block_valid?/1` invariant are
  section-local. The shared base paper + `open_editor` come from
  `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  # ── P3.1: every block type is creatable from the add-block UI ───────────────

  # Every type the add-block menu offers (the optgroup list, in order). The
  # per-type invariant (so a degraded default surfaces as a failure) lives in
  # `addable_block_valid?/1` below — module attributes cannot hold closures.
  @addable_block_types ~w(
    paragraph heading list callout code divider section
    eyebrow byline ingress pullquote
    diagram
    field-string field-slug field-text field-boolean field-datetime field-color field-select
    field-reference field-image
    composite arrayOf codelist localizedText
  )

  # The per-type invariant the freshly-built default block must satisfy.
  defp addable_block_valid?(%{"type" => "paragraph"}), do: true
  defp addable_block_valid?(%{"type" => "heading", "level" => 2}), do: true
  defp addable_block_valid?(%{"type" => "list", "ordered" => false}), do: true
  defp addable_block_valid?(%{"type" => "callout", "tone" => "info"}), do: true
  defp addable_block_valid?(%{"type" => "code"}), do: true
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
  defp addable_block_valid?(%{"type" => "field-string", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-slug", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-text", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-boolean", "value" => false}), do: true
  defp addable_block_valid?(%{"type" => "field-datetime", "value" => ""}), do: true
  defp addable_block_valid?(%{"type" => "field-color", "value" => "#000000"}), do: true

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
