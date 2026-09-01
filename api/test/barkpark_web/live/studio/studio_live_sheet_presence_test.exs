defmodule BarkparkWeb.Studio.StudioLiveSheetPresenceTest do
  @moduledoc """
  Sheets M4 — grid collaborator presence.

  Two LiveViewTest mounts on the same sheet prove the full presence loop
  through the real spine: the hosting StudioLive tracks each editor on the
  per-sheet topic (`Barkpark.Plugins.Sheets.Session.presence_topic/3` via
  `BarkparkWeb.Presence`); the SheetGrid component renders collaborators'
  cursors (colored outline + name tag), selection overlays and the
  emphasized editing tag; meta updates ride the component's `presence-meta`
  event (the hook's client-throttled frame) and the edit-start/commit/cancel
  editing lifecycle; a process exit becomes a presence leave. Colors are
  deterministic per user_id (`PresenceState.pick_color/1` — the studio
  in-bar identity convention, reused).

  `async: false` — sheet sessions are globally registered processes and
  presence diffs fan out across test-spawned LiveViews, same as the M2
  grid suite.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PresenceState

  @dataset "production"

  setup do
    stop_all_sessions()

    on_exit(fn ->
      stop_all_sessions()
      Application.delete_env(:barkpark, Barkpark.Plugins.Sheets.Session)
    end)

    put_cfg(debounce_ms: 60_000, idle_stop_ms: 60_000)
    seed_sheet_schema!()
    :ok
  end

  defp put_cfg(overrides) do
    base = Application.get_env(:barkpark, Barkpark.Plugins.Sheets.Session, [])

    Application.put_env(
      :barkpark,
      Barkpark.Plugins.Sheets.Session,
      Keyword.merge(base, overrides)
    )
  end

  defp stop_all_sessions do
    for {_, pid, _, _} <-
          DynamicSupervisor.which_children(Barkpark.Plugins.Sheets.SessionSupervisor),
        is_pid(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp seed_sheet_schema! do
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
  end

  defp create_sheet!(slug, cells) do
    {:ok, doc} =
      Content.create_document(
        "sheet",
        %{
          "doc_id" => slug,
          "content" => %{"locale" => "nb-NO", "tabs" => [%{"name" => "Data", "cells" => cells}]}
        },
        @dataset
      )

    doc
  end

  # Mount Studio on a sheet AS a specific identity — the same localStorage
  # connect params the studio in-bar presence reads (user_id + user_name;
  # no stored color, so the deterministic palette pick applies).
  defp open_as!(slug, user_id, user_name) do
    conn =
      Phoenix.ConnTest.build_conn()
      |> put_connect_params(%{"user_id" => user_id, "user_name" => user_name})

    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/sheet/#{slug}"))
    {view, with_target(view, "#sheet-grid-#{slug}"), html}
  end

  # Peer decoration lives on the overlay layer (one box per cursor, one rect
  # per selection), never on the tds — see the SheetGrid moduledoc. Missing
  # boxes render as "" so `eventually` retries instead of raising.
  defp peer_cursor(view, ref) do
    selector = ~s(.sheet-peer-cursor[data-peer-cell="#{ref}"])
    if has_element?(view, selector), do: view |> element(selector) |> render(), else: ""
  end

  defp peer_selection(view, range) do
    selector = ~s(.sheet-peer-sel[data-peer-range="#{range}"])
    if has_element?(view, selector), do: view |> element(selector) |> render(), else: ""
  end

  # Presence diffs (Phoenix.Tracker) and LV re-renders are asynchronous —
  # retry the assertion briefly instead of sleeping a fixed eternity.
  defp eventually(fun, tries \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(20)
      eventually(fun, tries - 1)
  end

  # ── join + color determinism ───────────────────────────────────────────────

  test "two editors on the same sheet see each other's join at the seeded A1 cursor" do
    create_sheet!("sp-join", %{"A1" => %{"v" => "x"}})
    {view1, _t1, _} = open_as!("sp-join", "alice-id-001", "Alice")
    {view2, _t2, _} = open_as!("sp-join", "bob-id-002", "Bob")

    # Each sees the OTHER's name tag parked at A1 (the tracked seed meta)…
    eventually(fn ->
      assert peer_cursor(view1, "A1") =~ "sheet-peer-tag"
      assert peer_cursor(view1, "A1") =~ "Bob"
      assert peer_cursor(view2, "A1") =~ "Alice"
    end)

    # …never their own (self is excluded from the peer list), and the tag
    # carries the deterministic palette color for the peer's user_id.
    refute peer_cursor(view1, "A1") =~ "Alice"
    refute peer_cursor(view2, "A1") =~ "Bob"
    assert peer_cursor(view1, "A1") =~ "background: #{PresenceState.pick_color("bob-id-002")}"
    assert peer_cursor(view2, "A1") =~ "background: #{PresenceState.pick_color("alice-id-001")}"
  end

  test "colors are deterministic per user_id from the fixed palette" do
    # Same user = same color, every call, and always a palette member.
    color = PresenceState.pick_color("carol-id-003")
    assert color == PresenceState.pick_color("carol-id-003")
    assert color =~ ~r/^#[0-9a-f]{6}$/

    palette = for uid <- 1..100, do: PresenceState.pick_color("user-#{uid}")
    assert palette |> Enum.uniq() |> length() <= 8
  end

  # ── cursor + selection ─────────────────────────────────────────────────────

  test "a presence-meta frame moves the peer cursor; a range renders the overlay" do
    create_sheet!("sp-cursor", %{})
    {view1, _t1, _} = open_as!("sp-cursor", "alice-id-001", "Alice")
    {_view2, t2, _} = open_as!("sp-cursor", "bob-id-002", "Bob")

    # Cursor move — the box leaves A1 and lands on B4 with the name tag.
    render_hook(t2, "presence-meta", %{"active" => "B4", "selection" => nil})

    eventually(fn ->
      assert peer_cursor(view1, "B4") =~ "sheet-peer-cursor"
      assert peer_cursor(view1, "B4") =~ "Bob"
      refute peer_cursor(view1, "A1") =~ "Bob"
    end)

    # Selection — ONE translucent rect covering exactly B2:C3 (default
    # 88x24 cells: x 44+88, y 25+24, two columns by two rows); anything
    # outside the rect stays clean because the rect ends at C3's edges.
    render_hook(t2, "presence-meta", %{"active" => "B2", "selection" => "B2:C3"})

    eventually(fn ->
      sel = peer_selection(view1, "B2:C3")
      assert sel =~ "sheet-peer-sel"
      assert sel =~ "left: 132px; top: 49px; width: 176px; height: 48px"
    end)
  end

  test "a malformed presence frame degrades to no cursor instead of erroring" do
    create_sheet!("sp-junk", %{})
    {view1, _t1, _} = open_as!("sp-junk", "alice-id-001", "Alice")
    {_view2, t2, _} = open_as!("sp-junk", "bob-id-002", "Bob")

    eventually(fn -> assert peer_cursor(view1, "A1") =~ "Bob" end)

    render_hook(t2, "presence-meta", %{"active" => "not-a-ref", "selection" => "junk"})

    eventually(fn -> refute render(view1) =~ "sheet-peer-tag" end)
  end

  # ── editing flag lifecycle ─────────────────────────────────────────────────

  test "edit-start emphasizes the peer tag on the edited cell; commit clears it" do
    create_sheet!("sp-edit", %{})
    {view1, _t1, _} = open_as!("sp-edit", "alice-id-001", "Alice")
    {view2, t2, _} = open_as!("sp-edit", "bob-id-002", "Bob")

    render_hook(t2, "cell-click", %{"ref" => "B2", "shift" => false})
    render_hook(t2, "edit-start", %{})

    eventually(fn ->
      assert peer_cursor(view1, "B2") =~ "sheet-peer-editing"
      assert peer_cursor(view1, "B2") =~ "Bob"
    end)

    render_hook(t2, "edit-commit", %{"value" => "42", "move" => "none"})

    eventually(fn ->
      # The soft lock lifts (LWW stood all along); the committed value
      # reached the other editor through the session delta.
      refute render(view1) =~ "sheet-peer-editing"
      assert render(view1) =~ ~s(data-v="42")
    end)

    # Cancel clears it too.
    render_hook(t2, "edit-start", %{})
    eventually(fn -> assert peer_cursor(view1, "B2") =~ "sheet-peer-editing" end)
    render_hook(t2, "edit-cancel", %{})
    eventually(fn -> refute render(view1) =~ "sheet-peer-editing" end)

    # view2 never saw a tag of ITSELF on the cell it edited (Alice's tag
    # sits parked at A1 — that one is legitimate).
    refute peer_cursor(view2, "B2") =~ "sheet-peer-tag"
  end

  # ── departure ──────────────────────────────────────────────────────────────

  test "a departing editor's cursor leaves with their process" do
    create_sheet!("sp-leave", %{})
    {view1, _t1, _} = open_as!("sp-leave", "alice-id-001", "Alice")
    {view2, _t2, _} = open_as!("sp-leave", "bob-id-002", "Bob")

    eventually(fn -> assert peer_cursor(view1, "A1") =~ "Bob" end)

    # Process exit -> presence leave -> the tag disappears for the survivor.
    Process.flag(:trap_exit, true)
    GenServer.stop(view2.pid)

    eventually(fn -> refute render(view1) =~ "Bob" end)
  end

  # ── render cost (review-phase measurement) ─────────────────────────────────

  test "MEASURE: a presence frame on a 500-row rendered sheet re-renders within budget" do
    cells =
      for r <- 1..500, c <- 1..8, into: %{} do
        {"#{<<?A + c - 1>>}#{r}", %{"v" => "r#{r}c#{c}"}}
      end

    create_sheet!("sp-bench", cells)
    {view, _t, _} = open_as!("sp-bench", "alice-id-001", "Alice")
    assert render(view) =~ ~s(data-ref="H500")

    # Synthetic peer frames pushed straight at the component — the same
    # send_update spine StudioLive's presence_diff handler rides. The
    # :sys.get_state barrier and the send_update leave THIS process, so
    # FIFO ordering guarantees the timed window covers the component
    # update + re-render + diff, nothing async. The barrier itself copies
    # the LV state to the test process (~ms on a 4_000-cell sheet), so the
    # honest per-frame cost is moving MINUS the no-op baseline: a no-op
    # frame (identical presences) marks no assigns changed and skips the
    # render outright, leaving pure barrier overhead.
    frame = fn ref ->
      peer = %{
        user_id: "bench-bob",
        name: "Bob",
        color: nil,
        tab: 0,
        active: ref,
        selection: "C2:D5",
        editing: nil
      }

      {us, _} =
        :timer.tc(fn ->
          Phoenix.LiveView.send_update(view.pid, BarkparkWeb.Studio.SheetGrid,
            id: "sheet-grid-sp-bench",
            presences: [peer]
          )

          :sys.get_state(view.pid)
        end)

      us
    end

    # ESTIMATOR: min-of-N, NOT the median.
    #
    # Every source of error in this measurement is ONE-SIDED — a sample can be
    # inflated by a GC pause, a scheduler preemption, or a peer agent hammering
    # the same box, but nothing can make the server do the work FASTER than it
    # actually does it. So the minimum of N draws is the maximum-likelihood
    # estimate of the true cost, and it converges DOWN toward it as N grows.
    #
    # The median does not: it sits in the middle of whatever noise the run drew,
    # and this statistic subtracts TWO independent medians, so the noise on both
    # samples compounds instead of cancelling. Measured spread of the median
    # form was ~17ms against a 10ms budget while the true signal is ≤~3ms —
    # which is how three unrelated PRs (#14072, #14074, #14003) lost the
    # required Elixir Test check in one 25-minute window on `frame_ms` 10.387.
    #
    # The fix is the estimator, not the budget: covering the median's noise
    # would need ≥25ms, which is ABOVE the ~15ms full-grid-re-render regression
    # this test exists to catch — i.e. a deleted test. min-of-N keeps `< 10`
    # meaningful. Verified fail-able: re-reading `@presences` inside the cell
    # comprehension (the pre-overlay-split shape) puts frame_ms at ~15ms and
    # this assertion RED under the min estimator.
    best = fn times -> Enum.min(times) end

    [_warmup | moving] = for i <- 0..10, do: frame.("B#{i + 2}")
    [_warmup | static] = for _ <- 0..10, do: frame.("B12")

    moving_ms = best.(moving) / 1000
    baseline_ms = best.(static) / 1000
    frame_ms = max(moving_ms - baseline_ms, 0.0)

    # The frames really re-rendered: the last cursor landed on B12.
    assert peer_cursor(view, "B12") =~ "Bob"

    IO.puts(
      "[sheets-presence-bench] 500-row (10-col) presence frame: " <>
        "#{Float.round(frame_ms, 2)}ms server cost " <>
        "(moving #{Float.round(moving_ms, 2)}ms - barrier baseline #{Float.round(baseline_ms, 2)}ms, n=10 minima)"
    )

    # The 10ms review budget — UNCHANGED. Before the overlay split +
    # derive_grid persistence this measured ~15ms (a full grid-body re-render
    # per frame); now only the overlay layer re-renders. The budget still sits
    # BELOW that regression, which is the whole point: widening it past 15ms to
    # absorb estimator noise would delete the test.
    assert frame_ms < 10
  end

  # ── bystander read access ──────────────────────────────────────────────────

  test "a third anonymous mount reads the sheet unaffected by presence" do
    create_sheet!("sp-anon", %{"A1" => %{"v" => "hello"}})
    {_view1, _t1, _} = open_as!("sp-anon", "alice-id-001", "Alice")
    {_view2, t2, _} = open_as!("sp-anon", "bob-id-002", "Bob")
    render_hook(t2, "presence-meta", %{"active" => "C3", "selection" => "C3:D4"})

    # No connect params at all — the dev fallback identity (random user_id,
    # "User xxxx" name) mounts fine and reads the live grid + both peers.
    {:ok, view3, html3} = live(build_conn(), scoped_studio("/d/#{@dataset}/studio/sheet/sp-anon"))

    assert html3 =~ ~s(data-test-id="sheet-table")
    assert html3 =~ ~s(data-v="hello")

    eventually(fn ->
      html = render(view3)
      assert html =~ "Alice"
      assert html =~ "Bob"
    end)
  end
end
