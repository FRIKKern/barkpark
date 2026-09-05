defmodule BarkparkWeb.Studio.PaperEditor.BlocksTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — core block CRUD + reorder + cross-source sync.

  Proves the editor's core contract: edits ARE DocPatchOps.

    1. A View ⇄ Edit toggle flips the paper pane into edit controls.
    2. Editing a block's text → a `patch-block` is applied; the read-only
       pane shows the new text with the SAME view pid (no remount).
    3. Adding a block → a new block appears (append-block).
    4. Deleting a block → it's gone (remove-block).
    5. Reordering a block → order changes (remove + insert-after / move-block).
    6. A `{:paper_block}` broadcast from ANOTHER source still streams into
       the editor — edits-are-ops, viewers stay in sync.

  Every assertion drives the LiveView through the real Content + PubSub
  spine; nothing bypasses `Content.apply_paper_block_op/3`.

  Shared surface (`@dataset`, `@slug`, `setup`, `seed_*`, `open_editor`) lives
  in `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

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

  test "Studio view renders stored blocks instead of a stale current-version body_html cache", %{
    conn: conn
  } do
    paper = Content.get_paper(@slug, @dataset)

    stale_content =
      paper.content
      |> Map.put("body_html", "<p>STALE STUDIO CACHE</p>")
      |> Map.put(
        "body_html_sv",
        Barkpark.PortableDoc.Render.body_html_render_version()
      )

    paper
    |> Ecto.Changeset.change(content: stale_content)
    |> Barkpark.Repo.update!()

    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

    assert html =~ "Original intro text."
    refute html =~ "STALE STUDIO CACHE"
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
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
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
    |> element(~s([data-test-id="paper-add-block"]))
    |> render_submit(wire_params(view, %{"block-type" => "paragraph"}))

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
    |> render_click(wire_params(view, %{"id" => "p-second"}))

    ids = Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"])
    refute "p-second" in ids
    assert "h-1" in ids
    assert "p-intro" in ids

    refute render(view) =~ ~s(data-edit-block-id="p-second")
  end

  # ── pdd-t2: doctrine template locks — no delete/move controls for a locked block ──

  # A template-shaped paper: a LOCKED title heading @0 + a LOCKED featured image @1
  # (the forced initial set, mirroring Content.Papers.Template), then an unlocked
  # body paragraph. Satisfies the server template gate (title heading at 0,
  # featured at 1) so upsert_paper accepts it.
  defp seed_locked_paper! do
    slug = "2026-05-24-locked-paper"

    blocks = [
      %{
        "id" => "lk-title",
        "type" => "heading",
        "level" => 1,
        "role" => "title",
        "locked" => true,
        "text" => "Locked Doctrine"
      },
      %{"id" => "lk-featured", "type" => "image", "role" => "featured", "locked" => true},
      %{
        "id" => "lk-body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Editable body."}]
      },
      %{
        "id" => "lk-body2",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Second body."}]
      }
    ]

    {:ok, _paper} =
      Barkpark.Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    slug
  end

  test "a locked block renders NO move/delete controls, only a calm lock note",
       %{conn: conn} do
    slug = seed_locked_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    edit_html = open_editor(view)

    # The locked title: none of the ▲ / ▼ / × controls render; the lock note does.
    title = block_html(edit_html, "lk-title")
    refute title =~ ~s(data-test-id="paper-delete-block")
    refute title =~ ~s(data-test-id="paper-move-up")
    refute title =~ ~s(data-test-id="paper-move-down")
    assert title =~ ~s(data-test-id="paper-locked-note")

    # The locked featured image is likewise controlless (locked placement).
    featured = block_html(edit_html, "lk-featured")
    refute featured =~ ~s(data-test-id="paper-delete-block")
    refute featured =~ ~s(data-test-id="paper-move-up")
    assert featured =~ ~s(data-test-id="paper-locked-note")

    # The UNLOCKED body keeps its full control set (the guard is surgical).
    body = block_html(edit_html, "lk-body")
    assert body =~ ~s(data-test-id="paper-delete-block")
    assert body =~ ~s(data-test-id="paper-move-up")
    assert body =~ ~s(data-test-id="paper-move-down")
    refute body =~ ~s(data-test-id="paper-locked-note")
  end

  test "a locked block's grip is inert; the block below the prefix can't move up",
       %{conn: conn} do
    slug = seed_locked_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    edit_html = open_editor(view)

    # The locked title: no drag affordance (no data-drag-grip, not draggable),
    # a data-block-locked marker (context menu + CSS hook), the template hint.
    title = block_html(edit_html, "lk-title")
    refute title =~ ~s(data-drag-grip)
    refute title =~ ~s(draggable="true")
    assert title =~ ~s(data-block-locked="true")
    assert title =~ "Part of the document template"

    # The first UNLOCKED block sits directly below the locked featured image —
    # moving it up would displace the locked block, so its ▲ is disabled while
    # ▼ and drag stay live.
    body = block_html(edit_html, "lk-body")
    assert body =~ ~s(data-drag-grip)
    refute body =~ ~s(data-block-locked)
    [_, up_tag] = Regex.run(~r/(<button[^>]*phx-value-dir="up"[^>]*>)/s, body)
    assert up_tag =~ "disabled"
    [_, down_tag] = Regex.run(~r/(<button[^>]*phx-value-dir="down"[^>]*>)/s, body)
    refute down_tag =~ "disabled"
  end

  test "locked placement holds against raw events: drag clamps, moves and deletes no-op",
       %{conn: conn} do
    slug = seed_locked_paper!()
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))
    open_editor(view)

    ids = fn ->
      Content.paper_blocks(slug, @dataset) |> Enum.map(& &1["id"])
    end

    assert ids.() == ["lk-title", "lk-featured", "lk-body", "lk-body2"]

    # 1) A drop at the very front (after-id "") would land the block ABOVE the
    #    locked prefix — it CLAMPS to directly below the featured image instead
    #    of erroring: the calm nearest-allowed landing.
    render_hook(
      view,
      "paper-move-block-to",
      wire_params(view, %{"id" => "lk-body2", "after-id" => ""})
    )

    assert ids.() == ["lk-title", "lk-featured", "lk-body2", "lk-body"]

    # 2) A drop between the locked blocks clamps the same way (idempotent here).
    render_hook(
      view,
      "paper-move-block-to",
      wire_params(view, %{"id" => "lk-body2", "after-id" => "lk-title"})
    )

    assert ids.() == ["lk-title", "lk-featured", "lk-body2", "lk-body"]

    # 3) Dragging a LOCKED block anywhere is a calm no-op.
    render_hook(
      view,
      "paper-move-block-to",
      wire_params(view, %{"id" => "lk-title", "after-id" => "lk-body"})
    )

    assert ids.() == ["lk-title", "lk-featured", "lk-body2", "lk-body"]

    # 4) A stale ▲ on the first unlocked block (its button is disabled in the
    #    DOM) is a calm no-op — it would displace the locked featured image.
    render_click(
      view,
      "paper-move-block",
      wire_params(view, %{"id" => "lk-body2", "dir" => "up"})
    )
    assert ids.() == ["lk-title", "lk-featured", "lk-body2", "lk-body"]

    # 5) A stale delete on a locked block is a calm no-op.
    render_click(view, "paper-delete-block", wire_params(view, %{"id" => "lk-featured"}))
    assert ids.() == ["lk-title", "lk-featured", "lk-body2", "lk-body"]

    # 6) The guards are surgical: unlocked blocks still reorder below the prefix.
    render_hook(
      view,
      "paper-move-block-to",
      wire_params(view, %{"id" => "lk-body", "after-id" => "lk-featured"})
    )

    assert ids.() == ["lk-title", "lk-featured", "lk-body", "lk-body2"]
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
    |> render_click(wire_params(view, %{"id" => "p-second", "dir" => "up"}))

    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["h-1", "p-second", "p-intro"]

    # Move h-1 down one slot → p-second, h-1, p-intro.
    view
    |> element(~s([data-edit-block-id="h-1"] button[phx-value-dir="down"]))
    |> render_click(wire_params(view, %{"id" => "h-1", "dir" => "down"}))

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
    |> render_click(wire_params(view, %{"id" => "p-second", "dir" => "up"}))

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
    render_hook(
      view,
      "paper-move-block-to",
      wire_params(view, %{"id" => "p-second", "after-id" => "h-1"})
    )

    assert Content.paper_blocks(@slug, @dataset) |> Enum.map(& &1["id"]) ==
             ["h-1", "p-second", "p-intro"]
  end

  test "the drag path with an empty after-id moves the block to the front",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
    open_editor(view)

    # Empty after-id ⇒ move-to-front (after: nil).
    render_hook(
      view,
      "paper-move-block-to",
      wire_params(view, %{"id" => "p-second", "after-id" => ""})
    )

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
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
      "op" => "patch-block",
      "id" => "p-intro",
      "patch" => %{"content" => [%{"type" => "text", "value" => "Edited while in edit mode."}]}
    })

    view_html = view |> element(~s([data-test-id="paper-edit-toggle"])) |> render_click()

    # View shows the EDITED text (re-streamed from the current blocks), and the
    # superseded original text is gone FROM THE PAPER SURFACE. Scoped to the
    # editor panel: the doc-list pane's row description (manifest-first rows,
    # pc-w3b) refreshes on the mutation broadcast, which this click-render
    # doesn't wait for — the whole-page refute would race it.
    refute view_html =~ ~s(data-test-id="studio-paper-block-editor")
    assert view_html =~ "Edited while in edit mode."
    paper_html = view |> element(~s([data-test-id="studio-paper-editor"])) |> render()
    refute paper_html =~ "Original intro text."

    # No remount.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
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

  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp wire_params(view, params) do
    Map.merge(params, %{"request_id" => Ecto.UUID.generate(), "if_rev" => paper_rev(view)})
  end
end
