defmodule BarkparkWeb.PaperLiveTest do
  @moduledoc """
  Gate-A surviving-sentinel test for the convergence MVP (masterplan Fig 6).

  Proves the "no reload" property: a paper renders on mount, and a broadcast
  of updated HTML re-assigns `@html` and is patched into the DOM **without
  remounting**. The proof is two-pronged:

    1. PID identity — the LiveView process pid is identical before and after
       the broadcast (a remount / push_navigate would spawn a new process).
    2. Sentinel survival — `#paper-sentinel`, rendered once at mount OUTSIDE
       the re-assigned container, is still present after the update (a teardown
       would remove it).

  If LiveView were tearing down + re-rendering on each update (the old
  goto-reload behaviour the masterplan replaces), the pid would change and the
  sentinel would be re-created from scratch — the assertions below would fail.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Papers

  @slug "2026-05-23-convergence-demo"

  defp seed_paper(html) do
    {:ok, paper} =
      Papers.upsert_paper(%{slug: @slug, body_html: html, event_type: "plan-written"})

    paper
  end

  describe "mount + live update (no reload)" do
    test "renders the seeded body HTML on mount", %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>Hello convergence</h1></section>))

      {:ok, _view, html} = live(conn, "/papers/#{@slug}")

      assert html =~ "Hello convergence"
      assert html =~ ~s(id="block-1")
      # The sentinel element is present at mount.
      assert html =~ ~s(id="paper-sentinel")
    end

    test "broadcast re-assigns @html; same pid + sentinel survive (no remount)",
         %{conn: conn} do
      seed_paper(~s(<section id="block-1"><h1>First</h1></section>))

      {:ok, view, html} = live(conn, "/papers/#{@slug}")

      # Pre-update state: original block present, the extra block is NOT.
      assert html =~ "First"
      assert html =~ ~s(id="block-1")
      refute html =~ ~s(id="block-2")
      assert html =~ ~s(id="paper-sentinel")

      pid_before = view.pid

      # Broadcast an UPDATED HTML carrying one extra block. This goes through
      # the real Content/PubSub spine: upsert_paper persists + broadcasts on
      # the per-doc topic the LiveView subscribed to at mount.
      {:ok, _} =
        Papers.upsert_paper(%{
          slug: @slug,
          body_html:
            ~s(<section id="block-1"><h1>First</h1></section>) <>
              ~s(<section id="block-2"><p>Second block streamed in</p></section>)
        })

      # Pull the post-update DOM. render/1 reflects assigns after handle_info.
      updated = render(view)

      # The new block now renders...
      assert updated =~ ~s(id="block-2")
      assert updated =~ "Second block streamed in"
      # ...alongside the original (diffed in place, not replaced).
      assert updated =~ ~s(id="block-1")
      assert updated =~ "First"

      # SENTINEL 1 — same process: no remount, no push_navigate/redirect.
      assert view.pid == pid_before
      assert Process.alive?(view.pid)

      # SENTINEL 2 — the mount-time marker survived the update; it was diffed,
      # not torn down and rebuilt.
      assert updated =~ ~s(id="paper-sentinel")
      # The marker still carries its mount-time data-slug (unchanged identity).
      assert updated =~ ~s(data-slug="#{@slug}")
    end

    test "renders an empty-state when no paper is stored for the slug", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/papers/never-saved")
      assert html =~ ~s(id="paper-empty")
      assert html =~ "No paper saved yet"
    end
  end

  describe "Gate-B: multi-block streaming (no reload across a sequence)" do
    @block_slug "2026-05-23-wave4-stream"

    defp seed_block_paper do
      blocks = [
        %{"id" => "b-intro", "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => "First block streamed."}]}
      ]

      {:ok, paper} =
        Papers.upsert_paper(%{slug: @block_slug, blocks: blocks, event_type: "plan-written"})

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

    test "mount streams the initial block keyed by its id", %{conn: conn} do
      seed_block_paper()

      {:ok, _view, html} = live(conn, "/papers/#{@block_slug}")

      # Stream container is present and renders the seeded block.
      assert html =~ ~s(phx-update="stream")
      assert html =~ ~s(data-block-id="b-intro")
      assert html =~ "First block streamed."
      assert html =~ ~s(id="paper-sentinel")
    end

    test "a SEQUENCE of appends each appear via the stream; sentinel + prior blocks + pid survive",
         %{conn: conn} do
      seed_block_paper()

      {:ok, view, html} = live(conn, "/papers/#{@block_slug}")
      assert html =~ "First block streamed."
      refute html =~ "data-block-id=\"b-2\""

      pid_before = view.pid

      # Append three blocks in sequence through the real context + PubSub spine.
      # Each apply_block_op renders the fragment, bumps rev, broadcasts a
      # {:paper_block, …} delta the LiveView (subscribed at mount) consumes.
      {:ok, _} = Papers.apply_block_op(@block_slug, append_block_op("b-2", "Second block."))
      {:ok, _} = Papers.apply_block_op(@block_slug, append_block_op("b-3", "Third block."))
      {:ok, _} = Papers.apply_block_op(@block_slug, append_block_op("b-4", "Fourth block."))

      rendered = render(view)

      # Every new block appears in the DOM, keyed by id, via the stream...
      assert rendered =~ ~s(data-block-id="b-2")
      assert rendered =~ "Second block."
      assert rendered =~ ~s(data-block-id="b-3")
      assert rendered =~ "Third block."
      assert rendered =~ ~s(data-block-id="b-4")
      assert rendered =~ "Fourth block."

      # ...the original block survived (it was never re-rendered)...
      assert rendered =~ ~s(data-block-id="b-intro")
      assert rendered =~ "First block streamed."

      # SENTINEL 1 — same process across the WHOLE sequence: no remount,
      # no push_navigate/redirect at any step = no reload.
      assert view.pid == pid_before
      assert Process.alive?(view.pid)

      # SENTINEL 2 — the mount-time marker survived every delta.
      assert rendered =~ ~s(id="paper-sentinel")
      assert rendered =~ ~s(data-slug="#{@block_slug}")
    end

    test "a patch-block delta patches one block in place; the rest are untouched",
         %{conn: conn} do
      seed_block_paper()
      {:ok, _} = Papers.apply_block_op(@block_slug, append_block_op("b-2", "Second block."))

      {:ok, view, _html} = live(conn, "/papers/#{@block_slug}")
      pid_before = view.pid

      patch = %{
        "op" => "patch-block",
        "id" => "b-intro",
        "patch" => %{"content" => [%{"type" => "text", "value" => "First block EDITED."}]}
      }

      {:ok, _} = Papers.apply_block_op(@block_slug, patch)
      rendered = render(view)

      assert rendered =~ "First block EDITED."
      refute rendered =~ "First block streamed."
      # Sibling block untouched.
      assert rendered =~ "Second block."
      # No remount.
      assert view.pid == pid_before
    end

    test "rev-gap recovery: a delta whose rev skips ahead triggers a full refetch",
         %{conn: conn} do
      seed_block_paper()
      {:ok, view, _html} = live(conn, "/papers/#{@block_slug}")
      pid_before = view.pid

      # Persist two blocks straight into the context (bumps rev), but hand the
      # LiveView a SINGLE delta whose rev is ahead of what it last saw — a
      # simulated dropped frame. The view must refetch the full doc.
      {:ok, _} = Papers.apply_block_op(@block_slug, append_block_op("b-2", "Recovered B2."))
      {:ok, last} = Papers.apply_block_op(@block_slug, append_block_op("b-3", "Recovered B3."))

      # Frame with a rev far ahead of the mount rev → gap → refetch path.
      send(
        view.pid,
        {:paper_block,
         %{
           op_kind: "append-block",
           block_id: "b-3",
           fragment_html: "<p>stale fragment ignored</p>",
           position: 2,
           rev: last.rev
         }}
      )

      rendered = render(view)

      # The refetch pulled the true current doc — both persisted blocks present,
      # the stale inline fragment was NOT used.
      assert rendered =~ "Recovered B2."
      assert rendered =~ "Recovered B3."
      refute rendered =~ "stale fragment ignored"
      # Still no remount.
      assert view.pid == pid_before
      assert rendered =~ ~s(id="paper-sentinel")
    end

    test "whole-HTML fallback still works: a :paper_updated broadcast re-assigns",
         %{conn: conn} do
      # An HTML-only paper (no blocks) keeps the Wave-3 re-assign path.
      slug = "wave4-html-fallback"
      {:ok, _} = Papers.upsert_paper(%{slug: slug, body_html: "<p id=\"v1\">v1</p>"})

      {:ok, view, html} = live(conn, "/papers/#{slug}")
      assert html =~ ~s(id="v1")
      refute html =~ ~s(id="v2")
      pid_before = view.pid

      {:ok, _} = Papers.upsert_paper(%{slug: slug, body_html: "<p id=\"v2\">v2 re-assigned</p>"})

      rendered = render(view)
      assert rendered =~ ~s(id="v2")
      assert rendered =~ "v2 re-assigned"
      # No remount on the fallback path either.
      assert view.pid == pid_before
      assert rendered =~ ~s(id="paper-sentinel")
    end
  end
end
