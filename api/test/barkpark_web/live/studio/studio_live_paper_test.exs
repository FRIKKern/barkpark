defmodule BarkparkWeb.Studio.StudioLivePaperTest do
  @moduledoc """
  In-Studio live paper view (convergence/papers-in-studio).

  Proves the two Part-2 requirements end-to-end inside StudioLive:

    1. Navigating to `/studio/:dataset/paper/:slug` renders the paper's blocks
       in the EDITOR pane WITH the desk structure pane still present (the left
       structure pane + the Papers list pane stay visible).
    2. A `{:paper_block, …}` broadcast streams a new block into the editor pane
       with NO remount — same view pid before/after, and the `#paper-sentinel`
       (rendered OUTSIDE the streamed container) survives the delta.

  This is the Studio-side mirror of `BarkparkWeb.BulldocsLiveTest`'s Gate-B
  streaming proof — the same Content/PubSub spine, now embedded in the
  multi-pane Studio instead of the standalone /papers/:slug page.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-05-24-studio-paper"

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
      %{"id" => "h-1", "type" => "heading", "text" => "Studio Paper"},
      %{
        "id" => "b-intro",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "First block streamed."}]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(%{slug: @slug, dataset: @dataset, blocks: blocks})

    paper
  end

  defp append_block_op(id, text) do
    %{
      "op" => "append-block",
      "block" => %{
        "id" => id,
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    }
  end

  setup do
    seed_paper_schema!()
    seed_block_paper!()
    :ok
  end

  test "navigating to /studio/:dataset/paper/:slug renders blocks in the editor pane with the structure pane present",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/studio/#{@dataset}/paper/#{@slug}"))

    # The left structure pane (root desk) is present...
    assert html =~ "Structure"
    # ...the Papers list pane is present (the desk structure stays visible)...
    assert html =~ "Papers"
    # ...and the paper opens in the EDITOR pane, NOT the field form.
    assert html =~ ~s(data-test-id="studio-paper-editor")
    assert html =~ ~s(data-test-id="studio-paper-shell")
    refute html =~ ~s(id="editor-form")

    # The paper's blocks render live (streamed), keyed by block id.
    assert html =~ ~s(phx-update="stream")
    assert html =~ ~s(data-block-id="b-intro")
    assert html =~ "First block streamed."
    assert html =~ "Studio Paper"

    # The no-reload sentinel is present at mount.
    assert html =~ ~s(id="paper-sentinel")
    assert html =~ ~s(data-slug="#{@slug}")
  end

  test "a {:paper_block} broadcast streams a new block into the pane with no remount (same pid)",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/studio/#{@dataset}/paper/#{@slug}"))

    assert html =~ "First block streamed."
    refute html =~ ~s(data-block-id="b-2")

    pid_before = view.pid

    # Append a block through the real Content + PubSub spine: apply_paper_block_op
    # renders the fragment, bumps rev, and broadcasts a {:paper_block, …} delta
    # on the per-doc topic the Studio subscribed to when the paper opened.
    {:ok, _} =
      Content.apply_paper_block_op(
        @slug,
        append_block_op("b-2", "Second block streamed."),
        @dataset
      )

    rendered = render(view)

    # The new block appears via the stream...
    assert rendered =~ ~s(data-block-id="b-2")
    assert rendered =~ "Second block streamed."
    # ...the original block survived (it was never re-rendered)...
    assert rendered =~ ~s(data-block-id="b-intro")
    assert rendered =~ "First block streamed."

    # SENTINEL 1 — same process: no remount, no push_navigate/redirect.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)

    # SENTINEL 2 — the mount-time marker survived the delta (diffed, not rebuilt).
    assert rendered =~ ~s(id="paper-sentinel")
    assert rendered =~ ~s(data-slug="#{@slug}")
  end

  test "a remove-block delta deletes the block from the pane (dom-id prefix matches the stream name)",
       %{conn: conn} do
    # First append a removable block so there is something to delete.
    {:ok, _} =
      Content.apply_paper_block_op(@slug, append_block_op("b-2", "Doomed block."), @dataset)

    {:ok, view, html} = live(conn, scoped_studio("/studio/#{@dataset}/paper/#{@slug}"))
    assert html =~ ~s(data-block-id="b-2")
    assert html =~ "Doomed block."

    pid_before = view.pid

    # remove-block broadcasts a {:paper_block, op_kind: "remove-block"} delta.
    {:ok, _} =
      Content.apply_paper_block_op(@slug, %{"op" => "remove-block", "id" => "b-2"}, @dataset)

    rendered = render(view)

    # The block is gone from the pane — proves stream_delete_by_dom_id matched
    # the rendered "paper_blocks-b-2" dom id (regression guard for the hyphen
    # vs underscore prefix bug).
    refute rendered =~ ~s(data-block-id="b-2")
    refute rendered =~ "Doomed block."
    # The intro block survived; still no remount.
    assert rendered =~ "First block streamed."
    assert view.pid == pid_before
  end

  test "jumping between papers swaps the editor content (no stale blocks from the prior paper)",
       %{conn: conn} do
    other_slug = "2026-05-24-other-paper"

    # A SECOND paper that deliberately REUSES the same block ids as the first
    # (`h-1`, `b-intro`) but with different content — the exact shape that, on
    # a naive shared stream, leaves paper A's DOM nodes reused under paper B's
    # block ids.
    {:ok, _} =
      Content.upsert_paper(%{
        slug: other_slug,
        dataset: @dataset,
        blocks: [
          %{"id" => "h-1", "type" => "heading", "text" => "Other Paper"},
          %{
            "id" => "b-intro",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Totally different body."}]
          }
        ]
      })

    # Open paper A. (Block BODY text — e.g. "First block streamed." — renders
    # ONLY in the editor pane; titles like "Studio Paper" also appear in the
    # Papers list pane, so we assert on block body text to scope to the editor.)
    {:ok, view, html} = live(conn, scoped_studio("/studio/#{@dataset}/paper/#{@slug}"))
    assert html =~ "First block streamed."
    assert html =~ ~s(data-slug="#{@slug}")

    pid_before = view.pid

    # Jump to paper B within the SAME LiveView (Studio-internal navigation).
    html_b = render_patch(view, scoped_studio("/studio/#{@dataset}/paper/#{other_slug}"))

    # The editor now shows paper B...
    assert html_b =~ ~s(data-slug="#{other_slug}")
    assert html_b =~ "Totally different body."
    # ...and NONE of paper A's block body lingers in the editor (the bug).
    refute html_b =~ "First block streamed."

    # Jump back to paper A — A's content returns cleanly, B's is gone.
    html_a = render_patch(view, scoped_studio("/studio/#{@dataset}/paper/#{@slug}"))
    assert html_a =~ ~s(data-slug="#{@slug}")
    assert html_a =~ "First block streamed."
    refute html_a =~ "Totally different body."

    # Same process throughout — these are push_patch navigations, not remounts.
    assert view.pid == pid_before
  end
end
