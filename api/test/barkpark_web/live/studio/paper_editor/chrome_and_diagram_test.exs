defmodule BarkparkWeb.Studio.PaperEditor.ChromeAndDiagramTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — article-chrome + diagram blocks + autosave.

    * article-chrome (barkpark-54kh) — eyebrow / byline / ingress / pullquote
      RENDER but had no Beta editor path. These prove default_block/2 + the
      per-block edit form + build_block_patch/2 land the correct portable-doc
      shape through the SAME paper-edit-block → patch-block pipeline the
      callout/code forms use.
    * diagram (barkpark-woxx) — the diagram block RENDERS (`<pre class="mermaid">`)
      but had no Beta editor path; default_block("diagram", …) yields the flat
      {source:"", caption:""} default and build_block_patch maps a
      {source, caption} form submission through the same pipeline.
    * per-block edit auto-save (barkpark-hogk) — the shared per-block edit
      <form> carries phx-change="paper-block-autosave" (phx-debounce=500); a
      render_change persists through the SAME build_block_patch → patch-block
      pipeline the explicit Save uses, WITHOUT a Save submit. The Save button
      stays a fallback.

  All three sections share `insert_chrome_block`, `submit_edit_form`,
  `block_after_edit`, `autosave_edit_form` and the `@slug` base paper — those
  helpers are section-local and live here. The shared base paper + `open_editor`
  come from `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  # ── article-chrome blocks (barkpark-54kh): insert + edit round-trips ───────

  # Insert a fresh chrome block of `type` through the add-block UI (the SAME
  # default_block/2 path the slash menu uses) and return its id. The editor must
  # already be open (the form lives in the block editor).
  defp insert_chrome_block(view, type) do
    view
    |> element(~s([data-test-id="paper-add-block"]))
    |> render_submit(wire_params(view, %{"block-type" => type}))

    Content.paper_blocks(@slug, @dataset) |> List.last() |> Map.get("id")
  end

  defp submit_edit_form(view, id, params) do
    view
    |> element(~s([data-edit-block-id="#{id}"] form.bp-paper-edit-form))
    |> render_submit(wire_params(view, Map.put(params, "block_id", id)))
  end

  defp block_after_edit(id),
    do: Content.paper_blocks(@slug, @dataset) |> Enum.find(&(&1["id"] == id))

  test "editing an eyebrow block writes a flat text string", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "eyebrow")

    submit_edit_form(view, id, %{"text" => "Field notes"})

    block = block_after_edit(id)
    assert block["type"] == "eyebrow"
    assert block["text"] == "Field notes"
  end

  test "editing a byline block splits ' · ' into an items list", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "byline")

    submit_edit_form(view, id, %{"text" => "Ada Lovelace · Grace Hopper"})

    block = block_after_edit(id)
    assert block["type"] == "byline"
    assert block["items"] == ["Ada Lovelace", "Grace Hopper"]
  end

  test "editing an ingress block wraps text in an inline content array", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "ingress")

    submit_edit_form(view, id, %{"text" => "The lead paragraph."})

    block = block_after_edit(id)
    assert block["type"] == "ingress"
    assert block["content"] == [%{"type" => "text", "value" => "The lead paragraph."}]
  end

  test "editing a pullquote block wraps text in an inline content array", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "pullquote")

    submit_edit_form(view, id, %{"text" => "A quote worth pulling."})

    block = block_after_edit(id)
    assert block["type"] == "pullquote"
    assert block["content"] == [%{"type" => "text", "value" => "A quote worth pulling."}]
  end

  test "a byline edit pre-fills its input from the items list joined by ' · '",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "byline")
    submit_edit_form(view, id, %{"text" => "Ada · Grace"})

    # Re-render the editor: the byline input is pre-filled with the re-joined
    # items (round-trips through the edit form, not just the patch).
    html = render(view)
    assert html =~ ~s(value="Ada · Grace")
  end

  # ── diagram block (barkpark-woxx): insert + edit round-trip ────────────────
  # The diagram block RENDERS (Render.Figures.diagram_html/3 → `<pre class="mermaid">`) but had
  # no Beta editor path. These prove default_block("diagram", …) yields the flat
  # {source:"", caption:""} default and build_block_patch maps a {source, caption}
  # form submission through the SAME paper-edit-block → patch-block pipeline.

  test "adding a diagram block yields the flat empty source+caption default",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "diagram")

    block = block_after_edit(id)
    # default_block("diagram", _) shape: type + flat empty source/caption strings.
    assert block["type"] == "diagram"
    assert block["source"] == ""
    assert block["caption"] == ""
  end

  test "editing a diagram block writes flat source + caption strings",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "diagram")

    submit_edit_form(view, id, %{"source" => "graph TD", "caption" => "Fig"})

    block = block_after_edit(id)
    # build_block_patch(%{"type"=>"diagram"}, …) maps source/caption verbatim.
    assert block["type"] == "diagram"
    assert block["source"] == "graph TD"
    assert block["caption"] == "Fig"
  end

  test "a diagram edit pre-fills its source textarea + caption input",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "diagram")
    submit_edit_form(view, id, %{"source" => "graph TD", "caption" => "Fig 1"})

    html = render(view)
    # Source round-trips into the textarea body; caption into the input value.
    assert html =~ "graph TD"
    assert html =~ ~s(value="Fig 1")
  end

  # ── barkpark-hogk: per-block edit form auto-saves on debounced change ───────
  # The shared per-block edit <form> now carries phx-change="paper-block-autosave"
  # (phx-debounce=500). A `render_change` on that form persists the new field
  # values through the SAME build_block_patch → patch-block pipeline the explicit
  # Save uses — WITHOUT a Save submit. The Save button stays as a fallback.

  # Fire a debounced change on the block's edit form (autosave path). The hidden
  # block_id rides along in the form; we pass it explicitly too (matching the
  # change params LiveView sends with the input that changed).
  defp autosave_edit_form(view, id, params) do
    view
    |> element(~s([data-edit-block-id="#{id}"] form.bp-paper-edit-form))
    |> render_change(wire_params(view, Map.put(params, "block_id", id)))
  end

  test "a callout block auto-saves on change (no Save submit)", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "callout")

    # phx-change → paper-block-autosave persists WITHOUT a render_submit.
    autosave_edit_form(view, id, %{
      "tone" => "warning",
      "title" => "Heads up",
      "text" => "Continuously saved body."
    })

    block = block_after_edit(id)
    assert block["type"] == "callout"
    assert block["tone"] == "warning"
    assert block["title"] == "Heads up"
    assert block["content"] == [%{"type" => "text", "value" => "Continuously saved body."}]
  end

  test "a code block auto-saves on change (no Save submit)", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "code")

    autosave_edit_form(view, id, %{"lang" => "elixir", "value" => "IO.puts(:ok)"})

    block = block_after_edit(id)
    assert block["type"] == "code"
    assert block["lang"] == "elixir"
    assert block["value"] == "IO.puts(:ok)"
  end

  test "a diagram block auto-saves source + caption on change (no Save submit)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "diagram")

    autosave_edit_form(view, id, %{"source" => "graph LR", "caption" => "Auto fig"})

    block = block_after_edit(id)
    assert block["type"] == "diagram"
    assert block["source"] == "graph LR"
    assert block["caption"] == "Auto fig"
  end

  test "autosave with an unknown/missing block_id is a quiet no-op (never crashes)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    pid_before = view.pid

    # Fire the autosave event directly with a block_id that resolves to nil →
    # build_block_patch(nil, …) → %{} → harmless patch-block on a missing id.
    render_hook(view, "paper-block-autosave", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
      "block_id" => "does-not-exist",
      "text" => "ignored"
    })

    # No remount, process still alive — the guard held.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  # Regression: the explicit Save (render_submit / paper-edit-block) still
  # persists exactly as before — autosave is purely additive.
  test "the explicit Save still persists a diagram edit (paper-edit-block fallback)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)
    id = insert_chrome_block(view, "diagram")

    submit_edit_form(view, id, %{"source" => "sequenceDiagram", "caption" => "Saved fig"})

    block = block_after_edit(id)
    assert block["type"] == "diagram"
    assert block["source"] == "sequenceDiagram"
    assert block["caption"] == "Saved fig"
  end

  test "a freshly-added field block can be removed via its delete control (remove-block)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    # Add a field-string, then delete it — the per-block × control fires a
    # remove-block op through the same pipeline, regardless of block type.
    view
    |> element(~s([data-test-id="paper-add-block"]))
    |> render_submit(wire_params(view, %{"block-type" => "field-string"}))

    new_id = Content.paper_blocks(@slug, @dataset) |> List.last() |> Map.get("id")
    assert new_id in (Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]))

    view
    |> element(~s([data-edit-block-id="#{new_id}"] [data-test-id="paper-delete-block"]))
    |> render_click(wire_params(view, %{"id" => new_id}))

    refute new_id in (Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]))
    refute render(view) =~ ~s(data-edit-block-id="#{new_id}")
  end

  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp wire_params(view, params) do
    Map.merge(params, %{"request_id" => Ecto.UUID.generate(), "if_rev" => paper_rev(view)})
  end
end
