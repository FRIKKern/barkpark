defmodule BarkparkWeb.Studio.StudioLiveInspectorDefaultTest do
  @moduledoc """
  studio-space-priority-desk `spd-b29` — the SERVER half of the bucket-aware
  inspector default (charter D91), and specifically the half the wave-6 browser
  proof could not cover.

  That proof drove real Chrome and settled the CASCADE half end to end: first
  frame closed, zero inspector-visible frames, and stamping `data-user-opened`
  by hand made the panel appear. But it stamped the marker from the console —
  it simulated the server. What was left unproven is whether LiveView keeps the
  marker across a diff that re-renders the `<aside>`, which is the difference
  between a real fix and one that silently reverts the first time anything else
  on the desk changes. That is the load-bearing test here.

  The other thing proved here is the toggle's DIRECTION. Below the `wide`
  bucket the desk paints the inspector closed while `sidebar_open` still says
  true — deliberately, because a server-seeded close cannot land before
  ~400ms and would be the flash D12 refused. So in that one state a click has
  to mean OPEN, not "flip the assign". `wide` must be untouched: it is where
  the inspector docks, where epic criterion 2 is measured, and where the
  round-2 floor slice takes its input (D92).

  Assertions run on the rendered HTML string plus LiveViewTest's own DOM
  engine (there is no Floki in this app's deps), matching the house style of
  `studio_live_width_bucket_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-07-20-spd-b29-inspector"

  setup do
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

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          dataset: @dataset,
          blocks: [
            %{"id" => "h-1", "type" => "heading", "text" => "Inspector Default"},
            %{
              "id" => "p-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "The visible measure."}]
            }
          ]
        })
      )

    :ok
  end

  defp open_paper(conn) do
    live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))
  end

  # The <aside>'s opening tag, so an assertion cannot accidentally match the
  # marker attribute somewhere else in the desk.
  defp aside_tag(html) do
    case Regex.run(~r/<aside[^>]*data-test-id="paper-metadata-sidebar"[^>]*>/, html) do
      [tag] -> tag
      nil -> flunk("the document inspector <aside> did not render at all")
    end
  end

  # Everything from the inspector's opening tag onward. Crude on purpose — it
  # only has to be sensitive to a change INSIDE the panel, which is all the
  # non-vacuity guard below needs.
  defp inspector_subtree(html) do
    case String.split(html, ~s(data-test-id="paper-metadata-sidebar"), parts: 2) do
      [_, rest] -> rest
      _ -> flunk("the document inspector <aside> did not render at all")
    end
  end

  describe "the first-paint default" do
    test "the inspector renders is-open but WITHOUT the user-opened marker, so the cascade paints it closed below wide",
         %{conn: conn} do
      {:ok, _view, html} = open_paper(conn)
      tag = aside_tag(html)

      # `is-open` is unchanged — the server default is deliberately NOT
      # bucket-seeded, because the server does not know the bucket this early.
      assert tag =~ "bp-doc-sidebar is-open"
      # ...and the marker the first-paint rule yields to is absent, which is
      # what makes `:not([data-user-opened])` match at first paint.
      refute tag =~ "data-user-opened"

      # Not conflated with collapsed: the body is still in the DOM. CSS-hidden
      # and collapsed are different states and the component must keep them so.
      assert html =~ ~s(id="bp-doc-sidebar-body")
    end
  end

  describe "below wide — the painted-closed state" do
    setup %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)

      # The bucket the WidthBucket hook reconciles after connect. A click
      # happens long after connect, so consulting it costs no first-paint
      # correctness — it paints nothing before the user acts.
      render_hook(view, "width-bucket", %{"bucket" => "standard"})
      {:ok, view: view}
    end

    test "ONE click on the collapse control opens the inspector and stamps the marker",
         %{view: view} do
      html = element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      tag = aside_tag(html)

      # This is the criterion the refuted CSS-only shape fails: there, a click
      # from the painted-closed state produces `is-collapsed`, and the control
      # toggles forever between "collapsed" and "open but off-canvas".
      assert tag =~ "bp-doc-sidebar is-open"
      assert tag =~ ~s(data-user-opened)
      assert html =~ ~s(id="bp-doc-sidebar-body")
    end

    test "a second click closes it, and the marker goes with it", %{view: view} do
      element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      html = element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      tag = aside_tag(html)

      assert tag =~ "bp-doc-sidebar is-collapsed"
      refute tag =~ "data-user-opened"
      # Collapsed REMOVES the body from the DOM — the state CSS-hidden is not.
      refute html =~ ~s(id="bp-doc-sidebar-body")
    end

    test "LiveView PRESERVES the marker across a diff that re-renders the <aside>",
         %{view: view} do
      # THE UNPROVEN PART. The browser proof stamped this attribute from the
      # console; nothing had yet shown the server keeps it when something else
      # re-renders the same element. `sidebar-toggle-section` is the honest
      # probe: it mutates `sidebar_collapsed`, which is consumed INSIDE this
      # <aside>, so the panel genuinely re-renders — but it never touches
      # `sidebar_user_opened`.
      opened = element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      assert aside_tag(opened) =~ "data-user-opened"

      after_diff = render_click(view, "sidebar-toggle-section", %{"section" => "relations"})
      tag = aside_tag(after_diff)

      # Non-vacuity guard. If the section toggle were a no-op the marker would
      # "survive" a diff that never happened, and this test would be green for
      # the wrong reason. Pin that the <aside>'s own subtree actually changed.
      assert inspector_subtree(after_diff) != inspector_subtree(opened), """
      the section toggle re-rendered nothing inside the inspector, so this \
      test proves nothing about diffs. Pick a probe that actually moves the \
      <aside>.
      """

      assert tag =~ ~s(data-user-opened), """
      the user-opened marker was DROPPED by a re-render of the <aside>. \
      The inspector would silently vanish below `wide` the first time any \
      other sidebar state changed.
      """

      assert tag =~ "bp-doc-sidebar is-open"
    end
  end

  describe "wide is unmoved (D92)" do
    test "at the wide bucket the toggle behaves exactly as it always has — one click collapses",
         %{conn: conn} do
      {:ok, view, html} = open_paper(conn)

      # `mount.ex` seeds `width_bucket: "wide"`; assert the pre-change
      # behaviour survives rather than trusting the seed silently.
      assert aside_tag(html) =~ "bp-doc-sidebar is-open"

      collapsed = element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      assert aside_tag(collapsed) =~ "bp-doc-sidebar is-collapsed"

      reopened = element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      assert aside_tag(reopened) =~ "bp-doc-sidebar is-open"
    end

    test "an explicit wide bucket does not change that", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "wide"})

      collapsed = element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      assert aside_tag(collapsed) =~ "bp-doc-sidebar is-collapsed"
    end
  end

  describe "the marker is per-document, not sticky" do
    test "opening a paper reseeds the flag false, so the default is bucket-aware again",
         %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "standard"})

      opened = element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()
      assert aside_tag(opened) =~ "data-user-opened"

      # A fresh open re-runs `sidebar_assigns/1`, which seeds the flag false.
      {:ok, _view2, fresh} = open_paper(conn)
      refute aside_tag(fresh) =~ "data-user-opened"
    end
  end
end
