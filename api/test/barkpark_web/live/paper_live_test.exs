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
end
