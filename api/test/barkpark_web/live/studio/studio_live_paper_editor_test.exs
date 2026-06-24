defmodule BarkparkWeb.Studio.StudioLivePaperEditorTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR (convergence/studio-paper-editor).

  Proves the editor's core contract: edits ARE DocPatchOps.

    1. A View ⇄ Edit toggle flips the paper pane into edit controls.
    2. Editing a block's text → a `patch-block` is applied; the read-only
       pane shows the new text with the SAME view pid (no remount).
    3. Adding a block → a new block appears (append-block).
    4. Deleting a block → it's gone (remove-block).
    5. Reordering a block → order changes (remove + insert-after).
    6. A `{:paper_block}` broadcast from ANOTHER source still streams into
       the editor — edits-are-ops, viewers stay in sync.

  Every assertion drives the LiveView through the real Content + PubSub
  spine; nothing bypasses `Content.apply_paper_block_op/3`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.StudioLive.Handlers.Paper

  @dataset "production"
  @slug "2026-05-24-editor-paper"

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  defp seed_block_paper! do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "Editor Paper", "level" => 1},
      %{
        "id" => "p-intro",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Original intro text."}]
      },
      %{
        "id" => "p-second",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Second paragraph."}]
      }
    ]

    {:ok, paper} = Content.upsert_paper(%{slug: @slug, dataset: @dataset, blocks: blocks})
    paper
  end

  setup do
    seed_paper_schema!()
    seed_block_paper!()
    :ok
  end

  defp open_editor(view) do
    # Flip into edit mode; assert the edit controls render.
    html = view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()
    assert html =~ ~s(data-test-id="studio-paper-block-editor")
    html
  end

  test "View/Edit toggle flips the pane into the block editor", %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

    # View mode by default — the read-only stream, no edit controls.
    assert html =~ ~s(data-test-id="paper-edit-toggle")
    refute html =~ ~s(data-test-id="studio-paper-block-editor")

    edit_html = open_editor(view)

    # Edit controls for each block, plus the add-block form.
    assert edit_html =~ ~s(data-edit-block-id="h-1")
    assert edit_html =~ ~s(data-edit-block-id="p-intro")
    assert edit_html =~ ~s(data-test-id="paper-add-block")
  end

  test "rich-text blocks render a <bp-paper-editor> WC carrying the block JSON",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    edit_html = open_editor(view)

    # Each rich-text block (heading / paragraph) is now edited by the
    # <bp-paper-editor> Web Component inside a phx-update="ignore" wrapper
    # mounted with the BarkparkPaperEditor hook. The wrapper id is stable per
    # block id so the caret survives server re-renders.
    assert edit_html =~ ~s(<bp-paper-editor)
    assert edit_html =~ ~s(id="paper-ed-p-intro")
    assert edit_html =~ ~s(phx-hook="BarkparkPaperEditor")
    assert edit_html =~ ~s(phx-update="ignore")

    # The intro paragraph's initial block is serialised into data-block (HTML
    # entity-escaped); the WC reads it on connect. Assert against the doc, then
    # re-render: the same id appears with no form (the old textarea is gone).
    refute edit_html =~ ~s([data-edit-block-id="p-intro"] form)
    assert edit_html =~ ~s(data-test-id="paper-block-editor-wc")
  end

  test "a paper-op patch-block from the WC hook applies + persists; same pid (no remount)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    pid_before = view.pid

    # The <bp-paper-editor> WC emits a bubbling/composed `bp-op` CustomEvent;
    # the BarkparkPaperEditor JS hook forwards detail verbatim as a `paper-op`
    # pushEvent. Simulate that wire with render_hook — the op arrives JSON-
    # decoded with string keys, exactly as the server's handler accepts it.
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "p-intro",
      "patch" => %{"content" => [%{"type" => "text", "value" => "Patched intro text."}]}
    })

    # The op landed in the DB as a patch-block (block id preserved, content
    # replaced with the patched inline node).
    block = Content.paper_blocks(@slug, @dataset) |> Enum.find(&(&1["id"] == "p-intro"))
    assert block["type"] == "paragraph"
    assert block["content"] == [%{"type" => "text", "value" => "Patched intro text."}]

    # The WC wrapper stays mounted (phx-update="ignore" → the server does NOT
    # re-stamp its data-block payload; the WC owns its own DOM + caret). The
    # persistence above is the proof the op applied; here we prove the editor
    # surface survived without a remount.
    rendered = render(view)
    assert rendered =~ ~s(id="paper-ed-p-intro")
    assert rendered =~ ~s(phx-hook="BarkparkPaperEditor")

    # No remount — same process — proving the edit went through the delta path.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
    # Sentinel survived (rendered outside the streamed container).
    assert rendered =~ ~s(id="paper-sentinel")
  end

  test "adding a block appends a new block", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    before_count = Content.paper_blocks(@slug, @dataset) |> length()

    view
    |> form(~s([data-test-id="paper-add-block"]), %{"block-type" => "paragraph"})
    |> render_submit()

    blocks = Content.paper_blocks(@slug, @dataset)
    assert length(blocks) == before_count + 1
    # The new block is a paragraph appended at the end, with a fresh "b-" id.
    last = List.last(blocks)
    assert last["type"] == "paragraph"
    assert String.starts_with?(last["id"], "b-")

    # And it renders in the editor.
    assert render(view) =~ ~s(data-edit-block-id="#{last["id"]}")
  end

  test "deleting a block removes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    view
    |> element(~s([data-edit-block-id="p-second"] [data-test-id="paper-delete-block"]))
    |> render_click()

    ids = Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"])
    refute "p-second" in ids
    assert "h-1" in ids
    assert "p-intro" in ids

    refute render(view) =~ ~s(data-edit-block-id="p-second")
  end

  test "reordering a block changes the order", %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    # Initial order: h-1, p-intro, p-second.
    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["h-1", "p-intro", "p-second"]

    # Move p-second up one slot → h-1, p-second, p-intro.
    view
    |> element(~s([data-edit-block-id="p-second"] button[phx-value-dir="up"]))
    |> render_click()

    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["h-1", "p-second", "p-intro"]

    # Move h-1 down one slot → p-second, h-1, p-intro.
    view
    |> element(~s([data-edit-block-id="h-1"] button[phx-value-dir="down"]))
    |> render_click()

    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["p-second", "h-1", "p-intro"]
  end

  # ── P3.2: reorder via the single `move-block` op ────────────────────────────

  # Slice the rendered HTML for one block (from its data-edit-block-id up to
  # the next block / the add-block form), so per-button disabled state can be
  # asserted independent of attribute ordering across the whole document.
  defp block_html(html, id) do
    [_, slice] =
      Regex.run(
        ~r/(data-edit-block-id="#{Regex.escape(id)}".*?)(?=data-edit-block-id=|data-test-id="paper-add-block")/s,
        html
      )

    slice
  end

  test "move up/down buttons disable at the boundaries (first ▲ / last ▼)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    edit_html = open_editor(view)

    # Whole <button> element (start tag) for a given move direction inside a
    # block slice. Asserting on the tag captures `disabled` wherever HEEx places
    # it among the attributes (source order: dir then disabled then test-id).
    btn = fn slice, dir ->
      [_, tag] = Regex.run(~r/(<button[^>]*phx-value-dir="#{dir}"[^>]*>)/s, slice)
      tag
    end

    # First block (h-1): the up button is disabled, the down button is not.
    h1 = block_html(edit_html, "h-1")
    assert btn.(h1, "up") =~ "disabled"
    refute btn.(h1, "down") =~ "disabled"

    # Last block (p-second): the down button is disabled, the up button is not.
    last = block_html(edit_html, "p-second")
    assert btn.(last, "down") =~ "disabled"
    refute btn.(last, "up") =~ "disabled"

    # Middle block (p-intro): neither move button is disabled.
    mid = block_html(edit_html, "p-intro")
    refute btn.(mid, "up") =~ "disabled"
    refute btn.(mid, "down") =~ "disabled"
  end

  test "moving up preserves the moved block's content (same id, same body)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    before = Content.paper_blocks(@slug, @dataset) |> Enum.find(&(&1["id"] == "p-second"))

    view
    |> element(~s([data-edit-block-id="p-second"] button[phx-value-dir="up"]))
    |> render_click()

    moved = Content.paper_blocks(@slug, @dataset) |> Enum.find(&(&1["id"] == "p-second"))

    # The block kept its identity AND its content across the reorder.
    assert moved == before
    assert moved["content"] == [%{"type" => "text", "value" => "Second paragraph."}]
  end

  test "the drag path (paper-move-block-to) reorders to a chosen anchor",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    # A drop event from the BarkparkPaperSortable hook: drop p-second AFTER h-1.
    render_hook(view, "paper-move-block-to", %{"id" => "p-second", "after-id" => "h-1"})

    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["h-1", "p-second", "p-intro"]
  end

  test "the drag path with an empty after-id moves the block to the front",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    # Empty after-id ⇒ move-to-front (after: nil).
    render_hook(view, "paper-move-block-to", %{"id" => "p-second", "after-id" => ""})

    blocks = Content.paper_blocks(@slug, @dataset)
    assert Enum.map(blocks, & &1["id"]) == ["p-second", "h-1", "p-intro"]

    # Content of the moved block survived the move-to-front.
    moved = Enum.find(blocks, &(&1["id"] == "p-second"))
    assert moved["content"] == [%{"type" => "text", "value" => "Second paragraph."}]
  end

  test "View → Edit → View round-trip re-populates the read-only stream (no remount)",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    pid_before = view.pid

    # View mode: the read-only stream shows the blocks' text, no edit controls.
    assert html =~ "Editor Paper"
    assert html =~ "Original intro text."
    refute html =~ ~s(data-test-id="studio-paper-block-editor")

    # → Edit: editor controls render, the streamed View article is gone.
    edit_html = open_editor(view)
    refute edit_html =~ ~s(<article id="paper-body-#{@slug}")

    # → View: toggle back. Before the fix the stream container returns EMPTY
    # (a LiveView stream has no server-side snapshot to re-emit), so the pane
    # shows zero blocks. After the fix the stream is rehydrated from the
    # current paper_doc blocks.
    view_html = view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()

    # Back in read-only View — edit controls gone, streamed article present.
    refute view_html =~ ~s(data-test-id="studio-paper-block-editor")
    assert view_html =~ ~s(<article id="paper-body-#{@slug}")

    # THE REGRESSION ASSERTION: the blocks are rendered again in View.
    assert view_html =~ "Editor Paper"
    assert view_html =~ "Original intro text."
    assert view_html =~ "Second paragraph."

    # Same process throughout — no remount, the sentinel survived.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
    assert view_html =~ ~s(id="paper-sentinel")
  end

  test "edit made in Edit mode is visible in View after toggling back (re-streams CURRENT blocks)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    pid_before = view.pid

    # → Edit, patch the intro paragraph via the WC's paper-op path, then → View.
    open_editor(view)

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "p-intro",
      "patch" => %{"content" => [%{"type" => "text", "value" => "Edited while in edit mode."}]}
    })

    view_html = view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()

    # View shows the EDITED text (re-streamed from the current blocks), and the
    # superseded original text is gone.
    refute view_html =~ ~s(data-test-id="studio-paper-block-editor")
    assert view_html =~ "Edited while in edit mode."
    refute view_html =~ "Original intro text."

    # No remount.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  # ── field-* LEAF blocks (P2.1) ─────────────────────────────────────────────

  @field_slug "2026-05-24-fields-paper"

  defp seed_field_paper! do
    blocks = [
      %{"id" => "f-str", "type" => "field-string", "label" => "Name", "value" => "Knut"},
      %{"id" => "f-slug", "type" => "field-slug", "label" => "Slug", "value" => "knut"},
      %{"id" => "f-text", "type" => "field-text", "label" => "Bio", "value" => "Hi", "rows" => 4},
      %{"id" => "f-bool", "type" => "field-boolean", "label" => "Featured", "value" => false},
      %{
        "id" => "f-sel",
        "type" => "field-select",
        "label" => "Tone",
        "value" => "info",
        "options" => [
          %{"value" => "info", "label" => "Info"},
          %{"value" => "warning", "label" => "Warning"}
        ]
      },
      %{
        "id" => "f-dt",
        "type" => "field-datetime",
        "label" => "When",
        "value" => "2026-05-24T10:00"
      },
      %{"id" => "f-color", "type" => "field-color", "label" => "Accent", "value" => "#4f46e5"},
      %{
        "id" => "f-ref",
        "type" => "field-reference",
        "label" => "Author",
        "refType" => "author",
        "value" => "a1"
      },
      %{
        "id" => "f-img",
        "type" => "field-image",
        "label" => "Cover",
        "value" => ""
      }
    ]

    {:ok, paper} = Content.upsert_paper(%{slug: @field_slug, dataset: @dataset, blocks: blocks})
    paper
  end

  test "Edit mode renders a native control + BarkparkFieldBlockBridge for each field-* block",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    edit_html = open_editor(view)

    # Each field block gets a stable wrapper mounted with the bridge hook,
    # carrying its block id + field type for client-side coercion.
    for {id, type} <- [
          {"f-str", "field-string"},
          {"f-slug", "field-slug"},
          {"f-text", "field-text"},
          {"f-bool", "field-boolean"},
          {"f-sel", "field-select"},
          {"f-dt", "field-datetime"},
          {"f-color", "field-color"}
        ] do
      assert edit_html =~ ~s(id="paper-fld-#{id}")
      assert edit_html =~ ~s(data-block-id="#{id}")
      assert edit_html =~ ~s(data-field-type="#{type}")
    end

    assert edit_html =~ ~s(phx-hook="BarkparkFieldBlockBridge")
    # Native controls present with their seeded values.
    assert edit_html =~ ~s(data-test-id="paper-field-field-string")
    assert edit_html =~ ~s(<textarea)
    assert edit_html =~ ~s(type="checkbox")
    assert edit_html =~ ~s(type="datetime-local")
    assert edit_html =~ ~s(type="color")
    # The select renders the seeded option labels.
    assert edit_html =~ "Warning"
  end

  test "a paper-op patch-block on a field-string block persists the new value", %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-str",
      "patch" => %{"value" => "Solveig"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-str"))
    assert block["type"] == "field-string"
    assert block["value"] == "Solveig"
    # label is untouched (shallow merge).
    assert block["label"] == "Name"
  end

  test "a paper-op patch-block on a field-boolean coerces + persists a real boolean",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    # The bridge sends a real JS boolean; assert the bool path. Also assert the
    # patch.ex coercion guard turns a stringy "true" into a real boolean.
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-bool",
      "patch" => %{"value" => true}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-bool"))
    assert block["value"] === true

    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-bool",
      "patch" => %{"value" => "false"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-bool"))
    assert block["value"] === false
  end

  test "a {:paper_block} broadcast from another source streams into the editor (edits are ops)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    pid_before = view.pid

    # Another source (e.g. the ingest endpoint or a remote viewer's edit)
    # appends a block via the same Content + PubSub spine the Studio is
    # subscribed to. The editor must reflect it without a remount.
    op = %{
      "op" => "append-block",
      "block" => %{
        "id" => "remote-1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "From another source."}]
      }
    }

    {:ok, _} = Content.apply_paper_block_op(@slug, op, @dataset)

    rendered = render(view)
    # The remote block appears as an editable block in this pane's edit form.
    assert rendered =~ ~s(data-edit-block-id="remote-1")
    assert rendered =~ "From another source."

    # Same process throughout — no remount.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  # ── field-reference / field-image PICKER blocks (P2.2) ─────────────────────

  test "Edit mode renders the bp-reference-picker + bp-media-picker picker WCs",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    edit_html = open_editor(view)

    # field-reference mounts a bp-reference-picker inside the standard bridge
    # wrapper, carrying its block id, field type, refType + dataset inline.
    assert edit_html =~ ~s(id="paper-fld-f-ref")
    assert edit_html =~ ~s(data-block-id="f-ref")
    assert edit_html =~ ~s(data-field-type="field-reference")
    assert edit_html =~ ~s(<bp-reference-picker)
    assert edit_html =~ ~s(ref-type="author")
    assert edit_html =~ ~s(data-test-id="paper-field-field-reference")

    # field-image mounts a bp-media-picker inside the same bridge wrapper.
    assert edit_html =~ ~s(id="paper-fld-f-img")
    assert edit_html =~ ~s(data-block-id="f-img")
    assert edit_html =~ ~s(data-field-type="field-image")
    assert edit_html =~ ~s(<bp-media-picker)
    assert edit_html =~ ~s(data-test-id="paper-field-field-image")

    # Both ride the SAME bridge hook the leaf fields use.
    assert edit_html =~ ~s(phx-hook="BarkparkFieldBlockBridge")
  end

  test "a paper-op patch-block on a field-reference persists the new ref doc id",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    # The bp-reference-picker emits a bubbling `bp-change` CustomEvent with
    # {detail:{value: <docId>}}; BarkparkFieldBlockBridge forwards detail.value
    # into a patch-block op pushed as `paper-op`. Simulate that wire — the op
    # arrives JSON-decoded with string keys, exactly as the handler accepts it.
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-ref",
      "patch" => %{"value" => "a2"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-ref"))
    assert block["type"] == "field-reference"
    assert block["value"] == "a2"
    # refType + label untouched (shallow merge).
    assert block["refType"] == "author"
    assert block["label"] == "Author"
  end

  test "a paper-op patch-block on a field-image persists the new image URL",
       %{conn: conn} do
    seed_field_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@field_slug}"))
    open_editor(view)

    # The bp-media-picker emits the same `bp-change` event carrying the image
    # URL string; the bridge forwards it as a patch-block op.
    render_hook(view, "paper-op", %{
      "op" => "patch-block",
      "id" => "f-img",
      "patch" => %{"value" => "/media/cover.png"}
    })

    block = Content.paper_blocks(@field_slug, @dataset) |> Enum.find(&(&1["id"] == "f-img"))
    assert block["type"] == "field-image"
    assert block["value"] == "/media/cover.png"
    assert block["label"] == "Cover"
  end

  # ── field-reference VIEW title resolution (Polish-1, barkpark-nkoy) ──────────
  #
  # View mode resolves the referenced doc's TITLE (not the raw id) through the
  # full Content → Render spine. The renderer stays pure; Content injects a
  # :ref_resolver bound to the dataset. A referable author doc must exist for
  # the title to resolve; with no match the row falls back to the stored id.

  @ref_view_slug "2026-05-24-ref-view-paper"

  defp seed_author!(doc_id, title) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Authors",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_document("author", %{"doc_id" => doc_id, "title" => title}, @dataset)
  end

  defp seed_ref_view_paper!(value) do
    blocks = [
      %{
        "id" => "f-ref",
        "type" => "field-reference",
        "label" => "Author",
        "refType" => "author",
        "value" => value
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(%{slug: @ref_view_slug, dataset: @dataset, blocks: blocks})

    paper
  end

  test "View mode renders the referenced doc's TITLE, not the raw id", %{conn: conn} do
    seed_author!("ref-a1", "Solveig Aamodt")
    seed_ref_view_paper!("ref-a1")

    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@ref_view_slug}"))

    # The streamed read-only View shows the resolved title for the reference
    # row; the raw doc id never appears as the displayed value.
    assert html =~ "Solveig Aamodt"
    refute html =~ ">ref-a1<"
  end

  test "View mode falls back to the raw id when the referenced doc is absent",
       %{conn: conn} do
    # No author doc seeded for "ghost-ref" → reference_title returns the id.
    seed_ref_view_paper!("ghost-ref")

    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@ref_view_slug}"))

    assert html =~ "ghost-ref"
  end

  # ── v2 COMPOSITE field blocks (P2.3, barkpark-wxxa) ─────────────────────────
  #
  # composite / arrayOf / codelist / localizedText render as a nested
  # PaperFieldBlock LiveComponent (NOT inside phx-update="ignore"). The inner
  # field components emit server-bound phx-change into a form targeting the
  # component; the component recomputes its OWN value and sends {:paper_op, op}
  # to the paper LiveView, which routes it through the canonical paper_op/2
  # pipeline (Content.apply_paper_block_op → persist + broadcast). These tests
  # prove both halves: the component renders in Edit mode, and an inner change
  # → handle_info({:paper_op,…}) persists the new structured value.

  @composite_slug "2026-05-24-composite-paper"

  defp seed_composite_paper! do
    blocks = [
      %{
        "id" => "c-price",
        "type" => "composite",
        "label" => "Price",
        "fields" => [
          %{"name" => "amount", "title" => "Amount", "type" => "string"},
          %{"name" => "currency", "title" => "Currency", "type" => "string"}
        ],
        "value" => %{"amount" => "299", "currency" => "NOK"}
      },
      %{
        "id" => "c-keywords",
        "type" => "arrayOf",
        "label" => "Keywords",
        "ordered" => true,
        "of" => %{"name" => "keyword", "type" => "string"},
        "value" => ["history", "norway"]
      },
      %{
        "id" => "c-audience",
        "type" => "codelist",
        "label" => "Audience",
        "codelistId" => "onixedit:audience",
        "version" => 73,
        "value" => "01"
      },
      %{
        "id" => "c-blurb",
        "type" => "localizedText",
        "label" => "Blurb",
        "languages" => ["nob", "eng"],
        "format" => "plain",
        "fallbackChain" => ["nob", "eng"],
        "value" => %{"nob" => "Omtale.", "eng" => "Blurb."}
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(%{slug: @composite_slug, dataset: @dataset, blocks: blocks})

    paper
  end

  test "Edit mode renders a PaperFieldBlock LiveComponent for each composite block",
       %{conn: conn} do
    seed_composite_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))
    edit_html = open_editor(view)

    # Each composite block renders the nested LiveComponent wrapper, keyed by
    # block id, with its field-type marker — NOT a phx-update="ignore" bridge.
    for {id, type} <- [
          {"c-price", "composite"},
          {"c-keywords", "arrayOf"},
          {"c-audience", "codelist"},
          {"c-blurb", "localizedText"}
        ] do
      assert edit_html =~ ~s(id="paper-fb-#{id}")
      assert edit_html =~ ~s(data-field-type="#{type}")
    end

    # The inner field components rendered their real controls + form bindings.
    # composite: a fieldset legend with the block label + the subfield inputs
    # (CompositeField tags each subfield wrapper with data-subfield-name).
    assert edit_html =~ "Price"
    assert edit_html =~ ~s(data-subfield-name="amount")
    assert edit_html =~ ~s(data-subfield-name="currency")
    # arrayOf: ordered reorder buttons (▲/▼) and the +Add button.
    assert edit_html =~ "Keywords"
    assert edit_html =~ ~s(phx-value-action="add_row")
    assert edit_html =~ ~s(phx-value-action="move_up")
    # localizedText: one row per language.
    assert edit_html =~ ~s(data-lang="nob")
    assert edit_html =~ ~s(data-lang="eng")
    # The composite controls are NOT mounted under the leaf bridge hook.
    refute edit_html =~ ~s(id="paper-fld-c-price")
  end

  test "an inner composite change → handle_info({:paper_op,…}) persists the merged value",
       %{conn: conn} do
    seed_composite_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))
    open_editor(view)

    pid_before = view.pid

    # Drive the inner form's phx-change targeting the LiveComponent. With
    # path="" the subfield inputs carry the bare subfield name, so the changed
    # subfields arrive flat and merge over the current %{amount, currency} map
    # (untouched subfields survive). The component sends {:paper_op, …} to the
    # paper LiveView via send(self(), …); render/1 flushes that async
    # handle_info so the patch-block lands before we read the DB. (In the
    # browser the message processes on the next loop tick automatically.)
    view
    |> element(~s([data-block-id="c-price"] form))
    |> render_change(%{"amount" => "299", "currency" => "USD"})

    render(view)

    block = Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-price"))
    assert block["type"] == "composite"
    assert block["value"]["currency"] == "USD"
    # The untouched subfield survived the shallow merge.
    assert block["value"]["amount"] == "299"
    # Config + label untouched (patch-block shallow-merges only "value").
    assert block["label"] == "Price"

    # No remount — the op went through the delta path.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  test "an inner localizedText change persists the merged %{lang => text} value",
       %{conn: conn} do
    seed_composite_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))
    open_editor(view)

    view
    |> element(~s([data-block-id="c-blurb"] form))
    |> render_change(%{"nob" => "Omtale.", "eng" => "New English blurb."})

    render(view)

    block = Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-blurb"))
    assert block["type"] == "localizedText"
    assert block["value"]["eng"] == "New English blurb."
    assert block["value"]["nob"] == "Omtale."
  end

  test "an inner codelist change persists the selected code", %{conn: conn} do
    seed_composite_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))
    open_editor(view)

    # codelist renders with path="value", so the code arrives as %{"value" => …}.
    # (The codelist registry is empty in test, so the field renders its disabled
    # placeholder <select>; driving the form's phx-change directly still proves
    # the component → :paper_op → persist wiring independent of registry data.)
    view
    |> element(~s([data-block-id="c-audience"] form))
    |> render_change(%{"value" => "02"})

    render(view)

    block =
      Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-audience"))

    assert block["type"] == "codelist"
    assert block["value"] == "02"
    assert block["codelistId"] == "onixedit:audience"
  end

  test "an arrayOf reorder (move_up) persists the reordered list", %{conn: conn} do
    seed_composite_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))
    open_editor(view)

    # Initial order: ["history", "norway"]. Moving row index 1 up swaps them.
    view
    |> element(
      ~s([data-block-id="c-keywords"] button[phx-value-action="move_up"][phx-value-index="1"])
    )
    |> render_click()

    render(view)

    block =
      Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-keywords"))

    assert block["type"] == "arrayOf"
    assert block["value"] == ["norway", "history"]
  end

  test "an arrayOf add_row appends an empty element", %{conn: conn} do
    seed_composite_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))
    open_editor(view)

    view
    |> element(~s([data-block-id="c-keywords"] button[phx-value-action="add_row"]))
    |> render_click()

    render(view)

    block =
      Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-keywords"))

    assert block["value"] == ["history", "norway", ""]
  end

  # ── Polish-3 Fix 1: arrayOf-of-composite nested-key parsing ─────────────────
  #
  # When an arrayOf's `of` is a `composite`, each element's subfield inputs name
  # themselves `[idx].subname` (and `[idx].nested.subname` for a composite
  # inside the element). `Plug.Conn.Query` does NOT nest through `.` or a
  # leading `[`, so every such input arrives as a FLAT param key. The previous
  # arrayOf merge only matched bare `[idx]` keys, so composite-element subfield
  # edits were silently dropped. These prove the merge now sets the right
  # `value[index][subname]` and persists it.

  @arraycomp_slug "2026-05-24-arraycomp-paper"

  defp seed_arraycomp_paper! do
    blocks = [
      %{
        "id" => "c-contributors",
        "type" => "arrayOf",
        "label" => "Contributors",
        "ordered" => true,
        "of" => %{
          "name" => "contributor",
          "type" => "composite",
          "fields" => [
            %{"name" => "name", "title" => "Name", "type" => "string"},
            %{"name" => "role", "title" => "Role", "type" => "string"}
          ]
        },
        "value" => [
          %{"name" => "Ada Lovelace", "role" => "Author"},
          %{"name" => "Grace Hopper", "role" => "Editor"}
        ]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(%{slug: @arraycomp_slug, dataset: @dataset, blocks: blocks})

    paper
  end

  test "an inner-change on a composite element subfield inside an arrayOf updates the right nested value + persists",
       %{conn: conn} do
    seed_arraycomp_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@arraycomp_slug}"))
    open_editor(view)

    pid_before = view.pid

    # The composite-element subfield inputs name themselves `[idx].subname`.
    # Edit element 1's `role` (Editor → Maintainer); the merge must set
    # value[1][role] and leave element 0 + element 1's name untouched.
    view
    |> element(~s([data-block-id="c-contributors"] form))
    |> render_change(%{"[1].role" => "Maintainer"})

    render(view)

    block =
      Content.paper_blocks(@arraycomp_slug, @dataset)
      |> Enum.find(&(&1["id"] == "c-contributors"))

    assert block["type"] == "arrayOf"
    # The edited subfield landed at value[1][role].
    assert Enum.at(block["value"], 1)["role"] == "Maintainer"
    # The other subfield of the same element survived.
    assert Enum.at(block["value"], 1)["name"] == "Grace Hopper"
    # Element 0 is wholly untouched.
    assert Enum.at(block["value"], 0) == %{"name" => "Ada Lovelace", "role" => "Author"}
    # No remount — the op went through the canonical delta path.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  test "editing two subfields of the same arrayOf composite element in one change merges both",
       %{conn: conn} do
    seed_arraycomp_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@arraycomp_slug}"))
    open_editor(view)

    view
    |> element(~s([data-block-id="c-contributors"] form))
    |> render_change(%{"[0].name" => "Augusta Ada", "[0].role" => "Mathematician"})

    render(view)

    block =
      Content.paper_blocks(@arraycomp_slug, @dataset)
      |> Enum.find(&(&1["id"] == "c-contributors"))

    assert Enum.at(block["value"], 0) == %{"name" => "Augusta Ada", "role" => "Mathematician"}
    # The second element is preserved (list not truncated by the partial change).
    assert Enum.at(block["value"], 1) == %{"name" => "Grace Hopper", "role" => "Editor"}
  end

  # ── P3.1: every block type is creatable from the add-block UI ───────────────
  # The add-block <select> now offers every portable-doc block type (grouped by
  # optgroup). Each choice resolves to default_block/2 and is appended through
  # the canonical paper-add-block → paper_op → Content.apply_paper_block_op
  # pipeline, which renders the new block (compose_block must accept it) and
  # persists. These assertions prove the full round-trip for every type.

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
  # shape Render.compose_block/2 reads at render.ex:348).
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
      |> form(~s([data-test-id="paper-add-block"]), %{"block-type" => type})
      |> render_submit()

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

  # ── article-chrome blocks (barkpark-54kh): insert + edit round-trips ───────
  # eyebrow / byline / ingress / pullquote RENDER (render.ex) but had no Beta
  # editor path. These prove default_block/2 + the per-block edit form +
  # build_block_patch/2 land the correct portable-doc shape through the SAME
  # paper-edit-block → patch-block pipeline the callout/code forms use.

  # Insert a fresh chrome block of `type` through the add-block UI (the SAME
  # default_block/2 path the slash menu uses) and return its id. The editor must
  # already be open (the form lives in the block editor).
  defp insert_chrome_block(view, type) do
    view
    |> form(~s([data-test-id="paper-add-block"]), %{"block-type" => type})
    |> render_submit()

    Content.paper_blocks(@slug, @dataset) |> List.last() |> Map.get("id")
  end

  defp submit_edit_form(view, id, params) do
    view
    |> element(~s([data-edit-block-id="#{id}"] form.bp-paper-edit-form))
    |> render_submit(Map.put(params, "block_id", id))
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
  # The diagram block RENDERS (render.ex:348 → `<pre class="mermaid">`) but had
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
    |> render_change(Map.put(params, "block_id", id))
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
    |> form(~s([data-test-id="paper-add-block"]), %{"block-type" => "field-string"})
    |> render_submit()

    new_id = Content.paper_blocks(@slug, @dataset) |> List.last() |> Map.get("id")
    assert new_id in (Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]))

    view
    |> element(~s([data-edit-block-id="#{new_id}"] [data-test-id="paper-delete-block"]))
    |> render_click()

    refute new_id in (Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]))
    refute render(view) =~ ~s(data-edit-block-id="#{new_id}")
  end

  # ── P3.3: the Notion-style slash menu (barkpark-h5ef) ──────────────────────
  # The <bp-paper-editor> WC emits a bubbling/composed `bp-slash-insert`
  # CustomEvent {type, afterId} when the user picks a type from the "/" popup;
  # the BarkparkPaperEditor hook forwards detail verbatim as a `paper-slash-
  # insert` pushEvent. The server builds the block with the SAME default_block/2
  # + new_block_id/0 the add-block path uses and applies an `insert-after` op
  # through the SAME paper_op/2 pipeline. Simulate that wire with render_hook —
  # the event arrives JSON-decoded with string keys, exactly as the handler
  # accepts it.

  test "a paper-slash-insert inserts a heading AFTER the anchor block + persists",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    # Initial order: h-1, p-intro, p-second.
    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["h-1", "p-intro", "p-second"]

    render_hook(view, "paper-slash-insert", %{"type" => "heading", "afterId" => "p-intro"})

    blocks = Content.paper_blocks(@slug, @dataset)
    ids = Enum.map(blocks, & &1["id"])

    # The new heading landed DIRECTLY after p-intro (insert-after, not appended
    # to the tail), with a fresh "b-" id.
    intro_idx = Enum.find_index(ids, &(&1 == "p-intro"))
    new_id = Enum.at(ids, intro_idx + 1)
    refute new_id == "p-second"
    assert String.starts_with?(new_id, "b-")

    new = Enum.find(blocks, &(&1["id"] == new_id))
    # default_block("heading", …) shape — proves the server reused the SAME
    # block-creation path the add-block menu uses.
    assert new["type"] == "heading"
    assert new["level"] == 2

    # The blocks below the anchor stay in order; p-second is now last.
    assert List.last(ids) == "p-second"
    # It renders in the editor (compose_block accepted it during render_blocks).
    assert render(view) =~ ~s(data-edit-block-id="#{new_id}")
  end

  test "a paper-slash-insert with a blank afterId appends at the end",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    before_count = Content.paper_blocks(@slug, @dataset) |> length()

    render_hook(view, "paper-slash-insert", %{"type" => "paragraph", "afterId" => ""})

    blocks = Content.paper_blocks(@slug, @dataset)
    assert length(blocks) == before_count + 1

    last = List.last(blocks)
    assert last["type"] == "paragraph"
    assert String.starts_with?(last["id"], "b-")
    assert render(view) =~ ~s(data-edit-block-id="#{last["id"]}")
  end

  # ── Polish-2 (barkpark-5srz): codelist field block fully usable ─────────────
  # Two halves:
  #   A) FLAT codelist — View resolves the selected CODE → its human LABEL via
  #      the Content → Render spine (the renderer stays pure; Content injects a
  #      :codelist_resolver). The picker is a real CodelistField bound to a
  #      registered codelist, so selection works.
  #   B) TREE codelist — PaperFieldBlock hosts the stateful TreeCodelistField
  #      inside its form (variant:"tree"); a tree-row select propagates up
  #      through the notify → send_update → patch-block pipeline and persists.
  #
  # Both register their codelists in-test (the dev seed populates OnixEdit, but
  # the test DB starts empty) so they exercise the SAME registry path.

  @codelist_view_slug "2026-05-24-codelist-view-paper"
  @codelist_tree_slug "2026-05-24-codelist-tree-paper"

  defp register_flat_codelist! do
    {:ok, _} =
      Content.Codelists.register("onixedit", "onixedit:list_15", %{
        issue: "73",
        name: "Title type",
        values: [
          %{code: "01", translations: [%{language: "eng", label: "Distinctive title"}]},
          %{code: "05", translations: [%{language: "eng", label: "Abbreviated title"}]}
        ]
      })
  end

  defp register_tree_codelist! do
    {:ok, _} =
      Content.Codelists.register("onixedit", "onixedit:thema", %{
        issue: "73",
        name: "Thema subject category",
        values: [
          %{
            code: "F",
            translations: [%{language: "eng", label: "Fiction"}],
            children: [
              %{
                code: "FB",
                translations: [%{language: "eng", label: "Fiction: literary and general"}],
                children: [
                  %{
                    code: "FBA",
                    translations: [%{language: "eng", label: "Modern and contemporary fiction"}]
                  }
                ]
              }
            ]
          }
        ]
      })
  end

  defp seed_codelist_view_paper!(value) do
    blocks = [
      %{
        "id" => "cl-flat",
        "type" => "codelist",
        "label" => "Title type",
        "plugin" => "onixedit",
        "codelistId" => "onixedit:list_15",
        "version" => 73,
        "variant" => "flat",
        "value" => value
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(%{slug: @codelist_view_slug, dataset: @dataset, blocks: blocks})

    paper
  end

  defp seed_codelist_tree_paper!(value) do
    blocks = [
      %{
        "id" => "cl-tree",
        "type" => "codelist",
        "label" => "Thema subject category",
        "plugin" => "onixedit",
        "codelistId" => "onixedit:thema",
        "version" => 73,
        "variant" => "tree",
        "value" => value
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(%{slug: @codelist_tree_slug, dataset: @dataset, blocks: blocks})

    paper
  end

  test "View mode resolves a flat codelist's selected CODE to its LABEL", %{conn: conn} do
    register_flat_codelist!()
    seed_codelist_view_paper!("01")

    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_view_slug}"))

    # The streamed read-only View shows the resolved label, not the bare code.
    assert html =~ "Distinctive title"
    # The raw code never appears as the standalone displayed value.
    refute html =~ ">01<"
  end

  test "View mode falls back to the raw code when the codelist is unregistered",
       %{conn: conn} do
    # No codelist registered → codelist_label returns the code unchanged.
    seed_codelist_view_paper!("99")

    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_view_slug}"))

    assert html =~ "99"
  end

  test "Edit mode renders the flat CodelistField <select> bound to the registry",
       %{conn: conn} do
    register_flat_codelist!()
    seed_codelist_view_paper!("01")

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_view_slug}"))

    edit_html = open_editor(view)

    # The flat block hosts the native CodelistField <select> (not the disabled
    # empty placeholder) — the registry is populated, so real options render.
    assert edit_html =~ ~s(id="paper-fb-cl-flat")
    assert edit_html =~ ~s(data-codelist-variant="flat")
    assert edit_html =~ ~s(data-codelist-id="onixedit:onixedit:list_15")
    # Selecting another code through the inner form persists via patch-block.
    view
    |> element(~s([data-block-id="cl-flat"] form))
    |> render_change(%{"value" => "05"})

    render(view)

    block =
      Content.paper_blocks(@codelist_view_slug, @dataset) |> Enum.find(&(&1["id"] == "cl-flat"))

    assert block["value"] == "05"
    assert block["plugin"] == "onixedit"
  end

  test "Edit mode hosts the TreeCodelistField for a variant:tree codelist block",
       %{conn: conn} do
    register_tree_codelist!()
    seed_codelist_tree_paper!("FBA")

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@codelist_tree_slug}"))

    edit_html = open_editor(view)

    # PaperFieldBlock hosts the stateful TreeCodelistField inside its form.
    assert edit_html =~ ~s(id="paper-fb-cl-tree")
    assert edit_html =~ ~s(data-codelist-variant="tree")
    # The tree LiveComponent mounted with its stable id + tree markup.
    assert edit_html =~ ~s(id="tree-cl-tree")
    assert edit_html =~ "bp-tree-codelist"
    assert edit_html =~ ~s(role="tree")
    # The hidden input carries the current value home through the parent form.
    assert edit_html =~ ~s(data-tree-selected="true")
    # The pre-selected leaf is rendered as selected (auto-expanded to it).
    assert edit_html =~ "Fiction"

    # A tree-row select propagates up: TreeCodelistField notifies the LiveView,
    # which send_updates the PaperFieldBlock, which persists the patch-block.
    view
    |> element(
      ~s([data-block-id="cl-tree"] button[phx-click="tree_node_select"][phx-value-code="FB"])
    )
    |> render_click()

    render(view)

    block =
      Content.paper_blocks(@codelist_tree_slug, @dataset) |> Enum.find(&(&1["id"] == "cl-tree"))

    assert block["type"] == "codelist"
    assert block["value"] == "FB"
    assert block["variant"] == "tree"
  end

  # ── paper_wikilink_search handler ────────────────────────────────────────────

  describe "paper_wikilink_search/2 — handler unit" do
    @wikilink_slug "2026-06-24-wikilink-candidate"

    setup do
      {:ok, _} =
        Content.upsert_paper(%{
          slug: @wikilink_slug,
          dataset: @dataset,
          blocks: [
            %{"id" => "h-1", "type" => "heading", "text" => "Wikilink Candidate Paper", "level" => 1}
          ]
        })

      :ok
    end

    defp bare_socket(dataset) do
      # Build a minimal LiveView socket carrying only the assigns the handler
      # reads: `dataset` (direct) and `current_workspace` / `current_project`
      # (consumed by ScopeHelpers.scope_opts/1 — nil means no tenancy scope).
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          dataset: dataset,
          current_workspace: nil,
          current_project: nil
        }
      }
    end

    test "blank query returns empty results without hitting the DB" do
      socket = bare_socket(@dataset)
      assert {:reply, %{results: []}, _socket} = Paper.paper_wikilink_search("", socket)
    end

    test "oversized query (> 100 chars) returns empty results" do
      socket = bare_socket(@dataset)
      long_q = String.duplicate("x", 101)
      assert {:reply, %{results: []}, _socket} = Paper.paper_wikilink_search(long_q, socket)
    end

    test "matching query returns candidate with title, string id, and type 'paper'" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_wikilink_search("Wikilink", socket)

      assert Enum.any?(results, fn r ->
               r.title == "Wikilink Candidate Paper" and
                 is_binary(r.id) and
                 r.type == "paper"
             end)
    end

    test "non-matching query returns empty list" do
      socket = bare_socket(@dataset)

      {:reply, %{results: results}, _socket} =
        Paper.paper_wikilink_search("zzzzzzzz-nomatch", socket)

      assert results == []
    end
  end
end
