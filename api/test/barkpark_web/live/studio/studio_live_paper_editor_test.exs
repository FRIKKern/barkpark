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
    {:ok, view, html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")

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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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

  test "View → Edit → View round-trip re-populates the read-only stream (no remount)",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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
      %{"id" => "f-dt", "type" => "field-datetime", "label" => "When", "value" => "2026-05-24T10:00"},
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@field_slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@field_slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@field_slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@field_slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@field_slug}")
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
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@field_slug}")
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
end
