defmodule BarkparkWeb.Studio.StudioLiveInspectorLadderTest do
  @moduledoc """
  spd-b39 — the Tier-2 ladder where it actually renders (charter D148/D151/D152).

  `pane_builder_inspector_test.exs` pins the pure table. This file pins the
  two things a pure table structurally cannot:

  1. THE WIRING HOLE (D152). `sidebar_user_opened` used to be seeded ONLY by
     `sidebar_assigns/1` in `shared/paper.ex`, reached only from
     `setup_paper_view`. `mount.ex` seeded `width_bucket` and no sidebar
     assign, so the key was measurably ABSENT on a fresh mount for the desk
     root, a type list, the field form, the sheet grid and the graph pane —
     PRESENT for paper alone. Reading it as `@sidebar_user_opened` in the
     pane comprehension therefore did not degrade, it DIED:
     `** (KeyError) key :sidebar_user_opened not found` raised through
     `Phoenix.LiveView.Diff.process_keyed/5`. These mounts are that crash's
     regression lock. They assert on rendered panes, not on the assign, so
     they stay honest if the seeding moves house later.

     The tempting alternative — `Map.get(assigns, :sidebar_user_opened, false)`
     at the read site — compiles, goes green, and silently pins every
     non-paper desk to false. That is the same hole wearing a passing test,
     which is why the seed lives in `mount.ex` and the read stays `@`.

  2. THE LADDER END TO END. That a summoned inspector at `standard` really
     does make the nav rail yield in the rendered DOM, and that `wide` moves
     nothing — including the detail that at `wide` the panel is seeded OPEN,
     so the FIRST click CLOSES it and it takes TWO clicks to raise
     `user_opened` there, versus ONE at `standard`. A Tier-1 test that clicks
     once at wide and expects "opened" is measuring the wrong state.

  Also pinned: the toggle stays a PURE assign flip. It must never call
  `rebuild_panes/1` — LiveView change-tracking already reaches the pane
  comprehension, and rebuilding would re-run the whole structure walk on
  every click.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @slug "2026-07-20-spd-b39-ladder"

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

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Posts",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "sheet",
          "title" => "Sheets",
          "icon" => "grid",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _post} =
      Content.create_document(
        "post",
        %{"doc_id" => "spd-b39-post", "title" => "Ladder Post", "status" => "published"},
        @dataset
      )

    {:ok, _sheet} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => "spd-b39-sheet",
          "title" => "Ladder Sheet",
          "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "Data", "cells" => %{}}]}
        },
        @dataset
      )

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @slug,
          dataset: @dataset,
          blocks: [
            %{"id" => "h-1", "type" => "heading", "text" => "Tier Two"},
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

  defp open_paper(conn), do: live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@slug}"))

  defp toggle(view),
    do: element(view, ~s([data-test-id="sidebar-toggle-panel"])) |> render_click()

  # Every rendered pane column's id, in row order. The ladder is exactly a
  # change in THIS list: `:hidden` panes are skipped server-side, so a pane
  # that yields disappears from the DOM rather than merely restyling.
  #
  # Tag-agnostic on purpose. `pane_column/1` renders a `:strip` as a
  # `<button class="pane-column pane-column--collapsed">` and a `:full` as a
  # `<section>`, so a tag whitelist would silently under-count the 44px back
  # affordance — which is the exact pane this slice is about keeping.
  defp pane_ids(html) do
    Regex.scan(~r/<[a-z]+[^>]*\bid="(pane-[a-z0-9-]+)"/, html)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  describe "D152 — every desk view mounts and renders with the fifth input wired" do
    # Each of these used to raise KeyError through Diff.process_keyed/5 the
    # moment the pane comprehension read `@sidebar_user_opened`. `live/2`
    # propagates that crash, so a bare successful mount IS the assertion —
    # but each case also asserts the pane row actually rendered, so a future
    # regression that swallows the panes cannot pass by merely not crashing.

    test "the desk root", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio"))
      assert pane_ids(html) != [], "the desk root rendered zero panes"
    end

    test "a type list pane", %{conn: conn} do
      {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post"))
      assert pane_ids(html) != [], "the type list rendered zero panes"
    end

    test "the field form (a plain document editor)", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/post/spd-b39-post"))

      assert pane_ids(html) != [], "the field form rendered zero panes"
    end

    test "the sheet grid", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/spd-b39-sheet"))

      assert pane_ids(html) != [], "the sheet grid rendered zero panes"
    end

    test "the graph pane", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, scoped_studio("/d/#{@dataset}/studio/graph/spd-b39-post"))

      assert pane_ids(html) != [], "the graph pane rendered zero panes"
    end

    test "the paper view, which already had the assign, is unchanged", %{conn: conn} do
      {:ok, _view, html} = open_paper(conn)
      assert pane_ids(html) != [], "the paper view rendered zero panes"
    end
  end

  describe "the ladder at standard" do
    test "summoning the inspector makes the nav rail yield to a single back strip",
         %{conn: conn} do
      {:ok, view, html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "standard"})

      before_ids = pane_ids(html)

      # Non-vacuity: the ladder can only REMOVE panes, so a desk that starts
      # with one pane proves nothing. Guard the premise, do not assume it.
      assert length(before_ids) >= 2, """
      the desk rendered #{length(before_ids)} pane(s) before the summon, so \
      "the rail yielded" is unfalsifiable here. Deepen the nav path.
      """

      opened = toggle(view)
      assert opened =~ "data-user-opened", "one click at standard must SUMMON the inspector"

      after_ids = pane_ids(opened)

      assert length(after_ids) == 1, """
      the rail did not yield. Panes before: #{inspect(before_ids)} \
      after: #{inspect(after_ids)} — the Tier-2 ladder must leave exactly one \
      44px back strip so the inspector docks in flow instead of overlaying \
      the prose.
      """

      assert List.last(before_ids) in after_ids, """
      the surviving pane is not the LAST one. The back affordance must be the \
      pane the user drilled from, not an arbitrary ancestor.
      """
    end

    test "dismissing the inspector restores the rail exactly", %{conn: conn} do
      {:ok, view, html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "standard"})
      before_ids = pane_ids(html)

      toggle(view)
      restored = toggle(view)

      refute restored =~ "data-user-opened"

      assert pane_ids(restored) == before_ids, """
      the rail did not come back the way it left. The ladder must be exactly \
      reversible — `/5` with the inspector closed is `/4` verbatim.
      """
    end
  end

  describe "TIER 1 — wide is unmoved" do
    test "raising user_opened at wide takes TWO clicks and moves zero panes", %{conn: conn} do
      {:ok, view, html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "wide"})

      before_ids = pane_ids(html)
      assert length(before_ids) >= 2, "premise: wide must start with a real rail to lose"

      # At wide the panel is seeded OPEN, so click one CLOSES it. A Tier-1
      # test that stops here and expects "opened" is measuring the wrong
      # state — this is the trap D151 names explicitly.
      first = toggle(view)
      refute first =~ "data-user-opened", "at wide the first click must CLOSE, not summon"
      assert pane_ids(first) == before_ids

      second = toggle(view)
      assert second =~ "data-user-opened", "the second click at wide raises user_opened"

      assert pane_ids(second) == before_ids, """
      TIER 1 MOVED. At wide, a summoned inspector changed the pane row from \
      #{inspect(before_ids)} to #{inspect(pane_ids(second))}. Viewport 1280 \
      and 1440 must move zero cells: there is no shortfall there to spend \
      navigation on.
      """
    end
  end

  describe "the toggle stays a pure assign flip" do
    test "summoning does not rebuild the pane tree", %{conn: conn} do
      {:ok, view, _html} = open_paper(conn)
      render_hook(view, "width-bucket", %{"bucket" => "wide"})

      panes_before = :sys.get_state(view.pid).socket.assigns.panes
      toggle(view)
      panes_after = :sys.get_state(view.pid).socket.assigns.panes

      # TERM-identical, not merely equal-looking: `rebuild_panes/1` re-runs
      # the structure walk and would hand back freshly built maps. The pane
      # comprehension re-renders anyway on a pure flip — LiveView change
      # tracking already reaches it — so rebuilding buys nothing and costs a
      # full desk walk on every click.
      assert panes_after === panes_before, """
      the sidebar toggle rebuilt the pane tree. It must stay a pure assign \
      flip (D151): change-tracking already re-renders the comprehension.
      """
    end
  end
end
