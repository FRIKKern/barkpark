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

  test "editing a block's text applies a patch-block; pane shows new text, same pid (no remount)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/studio/#{@dataset}/paper/#{@slug}")
    open_editor(view)

    pid_before = view.pid

    # Submit the intro paragraph's edit form with new text.
    view
    |> form(~s([data-edit-block-id="p-intro"] form), %{"text" => "Patched intro text."})
    |> render_submit()

    # The op landed in the DB as a patch-block (block id preserved, content
    # replaced with a single plain-text inline node).
    block = Content.paper_blocks(@slug, @dataset) |> Enum.find(&(&1["id"] == "p-intro"))
    assert block["type"] == "paragraph"
    assert block["content"] == [%{"type" => "text", "value" => "Patched intro text."}]

    rendered = render(view)
    # New text is visible in the editor; the original text is gone.
    assert rendered =~ "Patched intro text."
    refute rendered =~ "Original intro text."

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
end
