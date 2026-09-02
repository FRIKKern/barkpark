defmodule Barkpark.Plugins.Tasks.Web.BoardLiveTest do
  @moduledoc """
  Barkpark Projects — the read-only board LiveView (wave 1).

  Mounts at `/admin/projects` (the `:ops` admin bucket), renders the 5
  status-ladder columns over the REAL `type:task` corpus, paints the momentum
  header, the §1 white-ladder glyphs, and a GitHub badge on every mirrored card
  (`content.github`) — never on an unmirrored one. Also proves the Projects desk
  link is contributed AND survives into the built Structure tree.

  LiveView is exercised with `Phoenix.LiveViewTest` under `ConnCase` — never by
  booting `phx.server` (the codelist seed OOMs locally).
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Tasks.Board
  alias Barkpark.Tasks.Edge

  @admin_token "projects-board-admin-test-token"

  # Default Ecto telemetry event for a repo with `otp_app: :barkpark`.
  @repo_query_event [:barkpark, :repo, :query]

  setup do
    # HERMETIC GUARD (tlv-bl-board-live-connected-mount-regression): the board
    # mount projects the WHOLE `type:task` corpus of the production dataset, so
    # every exact-corpus assertion below (momentum pct, done counts, empty
    # banner, filter facets) is poisoned by any task document that survives in
    # the shared test database. Such rows are real: `cycle_fleet_test`'s
    # `Sandbox.unboxed_run` COMMITS its fixtures, and a killed run strands them
    # forever (`mix test` migrates, never resets). Deleting strays here runs
    # inside this test's sandbox transaction — it rolls back, the database
    # keeps its rows, and THIS test sees a clean corpus.
    Repo.delete_all(from(d in Document, where: d.type == "task"))

    {:ok, _} =
      Auth.create_token(@admin_token, "projects board admin", "production", [
        "read",
        "write",
        "admin"
      ])

    conn = build_conn() |> init_test_session(%{"api_token" => @admin_token})
    {:ok, conn: conn}
  end

  describe "the board LiveView at /admin/projects" do
    setup do
      # A small but real corpus, one card per column + a mirrored in_progress
      # card + a cancelled one folded to the tally. A and B block on W (which is
      # in_progress, ∴ not done) → they stay open/blocked; R has no blocker → it
      # derives ready.
      w =
        task("w1", "Wire the mirror job",
          lifecycle: "in_progress",
          priority: 2,
          assignee: "studio:doey",
          rev: "rev-w1",
          github: %{
            "repo" => "FRIKKern/barkpark",
            "issue" => 42,
            "state" => "synced",
            "synced_rev" => "rev-w1"
          }
        )

      a = task("a1", "Open with a live blocker", lifecycle: "open", priority: 3)

      _r =
        task("r1", "Claim me next — ready to go",
          lifecycle: "open",
          priority: 1,
          parent_id: "epic-1",
          labels: ["proj:board"],
          criteria: [%{"met" => true}, %{"met" => true}, %{"met" => false}]
        )

      b = task("b1", "Blocked on the mirror", lifecycle: "blocked")
      _d = task("d1", "Shipped the schema", lifecycle: "done", priority: 2)
      _c = task("c1", "Abandoned approach", lifecycle: "cancelled")

      # A and B depend on W (blocks: from = dependent, to = blocker).
      Repo.insert!(%Edge{from_id: a.id, to_id: w.id, kind: "blocks"})
      Repo.insert!(%Edge{from_id: b.id, to_id: w.id, kind: "blocks"})

      :ok
    end

    test "renders the five status-ladder columns", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      for col <- ~w(open ready in_progress blocked done) do
        assert html =~ ~s(data-col="#{col}"),
               "expected a column for #{col}"
      end
    end

    test "paints the momentum header with live counts + an animated bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ ~s(data-role="momentum")
      # in_flight: W(1) · ready: R(1) · done_today: D(1) · total non-cancelled
      # = W,A,R,B,D = 5, done = 1 → 20%.
      assert html =~ "1 in flight"
      assert html =~ "1 ready"
      assert html =~ "1 done today"
      assert html =~ "20%"
      assert html =~ ~s(data-role="momentum-bar")
      assert html =~ "width: 20%"
    end

    test "prints at least one §1 white-ladder glyph", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")
      # done ✓ and open/ready ○ are the identical Unicode the TUI paints.
      assert html =~ "✓"
      assert html =~ "○"
    end

    test "a ready card shows title, priority, goal, label, criteria", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ "Claim me next — ready to go"
      assert html =~ ~s(data-role="priority")
      assert html =~ "P1"
      assert html =~ ~s(data-role="goal")
      assert html =~ "epic-1"
      assert html =~ ~s(data-role="label")
      assert html =~ "proj:board"
      assert html =~ ~s(data-role="criteria")
      assert html =~ "2/3"
    end

    test "the in_progress card shows its worker", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")
      assert html =~ ~s(data-role="worker")
      assert html =~ "studio:doey"
    end

    test "a mirrored card carries a GitHub badge with #issue, href, and sync state",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ ~s(data-role="github-badge")
      assert html =~ ~s(href="https://github.com/FRIKKern/barkpark/issues/42")
      assert html =~ "#42"
      assert html =~ ~s(data-role="github-state")
      assert html =~ "synced"
      # synced_rev matches the doc rev → the synced (not detached) dot. Match
      # the element class, not the bare token (the <style> block defines
      # `.bp-gh-dot.is-synced`, so a substring check would be vacuous).
      assert html =~ ~s(class="bp-gh-dot is-synced")
    end

    test "an unmirrored card shows NO GitHub badge (exactly one badge on the board)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      badge_count =
        html
        |> String.split(~s(data-role="github-badge"))
        |> length()
        |> Kernel.-(1)

      assert badge_count == 1,
             "only the one mirrored card (W) should render a badge; got #{badge_count}"
    end

    test "cancelled folds to a dim tally line, never a column", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ ~s(data-role="cancelled-tally")
      assert html =~ "1 cancelled"
      refute html =~ ~s(data-col="cancelled")
    end
  end

  describe "GitHub badge edge cases" do
    test "a github stamp with no issue number renders NO badge (never a fabricated #)",
         %{conn: conn} do
      # A bare `detached` stamp can carry a state but no issue; the badge must
      # not paint a numberless `#` with a dead link.
      task("gh-noissue", "Detached, no issue",
        lifecycle: "open",
        github: %{"repo" => "FRIKKern/barkpark", "state" => "detached"}
      )

      {:ok, _view, html} = live(conn, "/admin/projects")

      refute html =~ ~s(data-role="github-badge")
    end

    test "a mirrored card whose synced_rev lags the live rev shows the detached dot",
         %{conn: conn} do
      task("gh-stale", "Mirror lags the current rev",
        lifecycle: "in_progress",
        rev: "rev-current",
        github: %{
          "repo" => "FRIKKern/barkpark",
          "issue" => 7,
          "state" => "synced",
          "synced_rev" => "rev-OLD"
        }
      )

      {:ok, _view, html} = live(conn, "/admin/projects")

      # The badge still renders (real issue), but the dot reads detached.
      # Match the element's class attribute, not the bare token — the inline
      # <style> block defines `.bp-gh-dot.is-synced`, so a substring check
      # would be vacuously true.
      assert html =~ ~s(data-role="github-badge")
      assert html =~ "#7"
      assert html =~ ~s(class="bp-gh-dot is-detached")
      refute html =~ ~s(class="bp-gh-dot is-synced")
    end
  end

  describe "empty state" do
    test "an empty corpus reads as an honest empty board, not a dead wall", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")
      assert html =~ ~s(data-role="board-empty")
      # The momentum header is still present — 0%, but always-on.
      assert html =~ ~s(data-role="momentum")
      assert html =~ "0%"
    end
  end

  # PROTECTIVE TEST (task-d8970b41d745e066): the authenticated board mount used
  # to run the full `Board.snapshot/1` projection on the DISCARDED disconnected
  # render, doubling the queries per open. It is now guarded behind
  # `connected?/1`. These two tests count the `edges`-table query — the unique
  # signature of `load_blocker_targets` inside `Board.snapshot` (nothing else on
  # the board mount reads task_edges) — to prove 2× → 1×.
  describe "disconnected mount elides the Board.snapshot projection" do
    setup do
      # A single task guarantees `load_blocker_targets` fires its edges query on
      # the projection — its guard clause skips the query for an empty corpus.
      task("solo1", "Wire the pipeline", lifecycle: "in_progress", priority: 1)
      :ok
    end

    test "the disconnected (dead) render runs ZERO board-projection queries and paints a loading skeleton",
         %{conn: conn} do
      {conn, edge_reads} = count_edge_queries(fn -> get(conn, "/admin/projects") end)

      body = html_response(conn, 200)
      # The dead render shows the loading skeleton, NOT the projected board.
      assert body =~ ~s(data-test-id="board-loading")
      refute body =~ "Wire the pipeline"

      # Board.snapshot's load_blocker_targets never ran on the discarded mount.
      assert edge_reads == 0,
             "the disconnected mount must issue zero board-projection (edges) queries, " <>
               "got #{edge_reads}"
    end

    test "the connected mount runs Board.snapshot exactly once (2x -> 1x)", %{conn: conn} do
      # `live/2` does the disconnected render THEN connects. The disconnected leg
      # now contributes 0 edges queries (the fix), so the ONE edges query across
      # the whole flow proves the snapshot runs a single time — on connect.
      {{:ok, _view, html}, edge_reads} =
        count_edge_queries(fn -> live(conn, "/admin/projects") end)

      # Behavior parity: the connected view shows the same data as before.
      assert html =~ "Wire the pipeline"

      assert edge_reads == 1,
             "Board.snapshot must run exactly once (on connect), got #{edge_reads} edges queries"
    end
  end

  describe "desk wiring" do
    test "the plugin contributes a Projects desk link" do
      items = Barkpark.Plugins.Tasks.desk_items("production")

      assert Enum.any?(
               items,
               &(&1[:type] == :link and &1[:path] == "/admin/projects" and
                   &1[:label] == "Projects")
             )
    end

    test "the Projects link survives into the built desk tree" do
      tree = Barkpark.Structure.build("projects_desk_probe")

      node =
        Enum.find(tree.items, fn n ->
          n.type == :plugin_link and n.filter == "/admin/projects"
        end)

      assert match?(%Barkpark.Structure.Node{title: "Projects"}, node),
             "the /admin/projects link must appear in the desk, got #{inspect(node)}"
    end
  end

  describe "Board.build/2 (pure organizer)" do
    test "attaches subtask lineage summaries off parent_id (wave 12)" do
      cards = [
        card("in_progress", doc_id: "par", title: "Parent"),
        card("done", doc_id: "kid-done", parent_id: "par"),
        card("in_progress",
          doc_id: "kid-wip",
          parent_id: "par",
          title: "Active child",
          worker: "w1"
        ),
        card("cancelled", doc_id: "kid-gone", parent_id: "par"),
        card("open", doc_id: "solo")
      ]

      board = Board.build(cards, now: ~U[2026-07-08 12:00:00Z])

      # cancelled children never count; the in-flight child is the focus.
      assert board.cards_by_id["par"].sub == %{
               total: 2,
               done: 1,
               active: %{title: "Active child", worker: "w1"}
             }

      assert board.cards_by_id["solo"].sub == nil
    end

    test "buckets, derives the ready overlay, folds cancelled, and computes momentum" do
      now = ~U[2026-07-07 12:00:00Z]

      cards = [
        card("in_progress"),
        card("open", blocker_statuses: ["in_progress"]),
        card("open"),
        card("blocked", blocker_statuses: ["in_progress"]),
        card("blocked", blocker_statuses: ["done"]),
        card("done", updated_at: now),
        card("cancelled")
      ]

      board = Board.build(cards, now: now)

      assert length(board.columns.in_progress) == 1
      assert length(board.columns.open) == 1
      # open-no-deps + blocked-with-all-deps-done both derive ready.
      assert length(board.columns.ready) == 2
      assert length(board.columns.blocked) == 1
      assert length(board.columns.done) == 1
      assert board.cancelled_count == 1

      assert board.momentum.in_flight == 1
      assert board.momentum.ready == 2
      assert board.momentum.done_today == 1
      # 6 non-cancelled, 1 done → round(1/6*100) = 17.
      assert board.momentum.pct == 17

      # every enriched card carries a §1 color_role + glyph.
      ip = hd(board.columns.in_progress)
      assert ip.color_role == :in_progress
      assert ip.glyph == "⠋"
    end

    test "ready sorts by priority ascending, nulls last" do
      cards = [
        card("open", doc_id: "p-nil", priority: nil),
        card("open", doc_id: "p-3", priority: 3),
        card("open", doc_id: "p-1", priority: 1)
      ]

      board = Board.build(cards, now: DateTime.utc_now())
      order = Enum.map(board.columns.ready, & &1.doc_id)
      assert order == ["p-1", "p-3", "p-nil"]
    end
  end

  describe "Board.card_from_broadcast/3 (pure, wave 2 + W19 field-vis seal)" do
    test "projects worker/labels/priority/github and carries prev blocker_statuses" do
      prev = card("open", doc_id: "bc-1", blocker_statuses: ["done", "open"])

      doc =
        msg_doc("bc-1", "Wire the mirror",
          status: "published",
          content: %{
            "lifecycle_status" => "in_progress",
            "priority" => 2,
            "parent_id" => "epic-9",
            "labels" => ["proj:board", "infra"],
            "assignee" => "studio:doey",
            "acceptance_criteria" => [%{"met" => true}, %{"met" => false}],
            "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 42, "state" => "synced"}
          }
        )

      c = Board.card_from_broadcast(doc, prev, all_readable())

      assert c.doc_id == "bc-1"
      assert c.title == "Wire the mirror"
      assert c.lifecycle_status == "in_progress"
      assert c.priority == 2
      assert c.parent_id == "epic-9"
      assert c.labels == ["proj:board", "infra"]
      assert c.worker == "studio:doey"
      assert c.criteria == %{met: 1, total: 2}
      assert c.github["issue"] == 42
      # the event carries no dependency graph → the prev card's readiness inputs
      # are carried forward so an already-known card keeps its blocker statuses.
      assert c.blocker_statuses == ["done", "open"]
    end

    test "worker falls back to the claim worker, and an unseen card gets [] blockers" do
      doc =
        msg_doc("bc-2", "Claimed by an agent",
          content: %{
            "lifecycle_status" => "in_progress",
            "claim" => %{"worker" => "cmux-7"}
          }
        )

      c = Board.card_from_broadcast(doc, nil, all_readable())

      assert c.worker == "cmux-7"
      # unseen (prev == nil) → empty blockers; readiness waits for :refresh.
      assert c.blocker_statuses == []
    end

    test "the readable? predicate redacts EXACTLY the 7 gated text/PII fields, ungated stays" do
      # A predicate that marks the schema-private text/PII fields unreadable —
      # the same set `to_card/4` gates. `lifecycle_status`/`github`/
      # `github_synced`/`blocker_statuses` are NOT in this set (parity law).
      private = ~w(priority parent_id labels assignee claim description design_doc
                   acceptance_criteria)
      redacting = fn field -> field not in private end

      prev = card("open", doc_id: "bc-sec", blocker_statuses: ["done", "open"])

      doc =
        msg_doc("bc-sec", "Sealed broadcast",
          content: %{
            "lifecycle_status" => "in_progress",
            "priority" => 2,
            "parent_id" => "epic-9",
            "labels" => ["proj:board"],
            "assignee" => "studio:doey",
            "description" => "SECRET-BODY-should-not-leak",
            "design_doc" => "SECRET-DESIGN-should-not-leak",
            "acceptance_criteria" => [
              %{"criterion" => "SECRET-CRITERION", "met" => false}
            ],
            "github" => %{"repo" => "FRIKKern/barkpark", "issue" => 42, "state" => "synced"}
          }
        )

      c = Board.card_from_broadcast(doc, prev, redacting)

      # the 7 gated fields are redacted to their empty/nil value…
      assert c.priority == nil
      assert c.parent_id == nil
      assert c.labels == []
      assert c.worker == nil
      assert c.next_criterion == nil
      assert c.criteria_list == nil
      assert c.description_excerpt == nil
      assert c.design_doc == nil

      # …while the UNGATED fields still project (parity with #5470 peek + #5779
      # snapshot): lifecycle, github, github_synced, and the carried blockers.
      assert c.title == "Sealed broadcast"
      assert c.lifecycle_status == "in_progress"
      assert c.github["issue"] == 42
      assert c.github_synced == false
      assert c.blocker_statuses == ["done", "open"]
      # the derived criteria COUNT stays ungated (count-vs-text law) — text gone,
      # tally intact.
      assert c.criteria == %{met: 0, total: 1}
    end

    test "a fail-closed predicate (fn _ -> false end) redacts every gated field" do
      doc =
        msg_doc("bc-fc", "Disconnected-shape",
          content: %{
            "lifecycle_status" => "open",
            "priority" => 1,
            "labels" => ["x"],
            "assignee" => "w",
            "description" => "SECRET"
          }
        )

      c = Board.card_from_broadcast(doc, nil, fn _ -> false end)

      assert c.priority == nil
      assert c.labels == []
      assert c.worker == nil
      assert c.description_excerpt == nil
      # ungated survive even under fail-closed.
      assert c.lifecycle_status == "open"
    end
  end

  describe "Board.apply_change/3 (pure, wave 2)" do
    test "moves a card open -> in_progress and bumps in_flight, kind == :moved" do
      t = ~U[2026-07-07 09:00:00Z]
      # an open card with a live (non-done) blocker sits in :open, not :ready.
      board =
        Board.build(
          [card("open", doc_id: "mv1", blocker_statuses: ["in_progress"], updated_at: t)],
          now: t
        )

      assert board.momentum.in_flight == 0
      prev = board.cards_by_id["mv1"]

      moved =
        Board.card_from_broadcast(
          msg_doc("mv1", "Now working", content: %{"lifecycle_status" => "in_progress"}),
          prev,
          all_readable()
        )

      {board, change} = Board.apply_change(board, moved)

      assert change.kind == :moved
      assert change.from_col == :open
      assert change.to_col == :in_progress
      assert board.momentum.in_flight == 1
      assert Enum.map(board.columns.in_progress, & &1.doc_id) == ["mv1"]
      assert board.columns.open == []
    end

    test "a fresh close bumps done_today monotonically, prepends to a windowed done column, and pct uses the full pre-cap count" do
      now = ~U[2026-07-07 12:00:00Z]

      # 12 already-done cards (dated today) fill the window exactly, plus one
      # in_progress card about to close.
      done_cards =
        for i <- 1..12 do
          card("done",
            doc_id: "d-#{i}",
            updated_at: DateTime.add(now, -i * 60, :second)
          )
        end

      wip = card("in_progress", doc_id: "wip", updated_at: DateTime.add(now, -1, :hour))

      board = Board.build(done_cards ++ [wip], now: now)

      assert board.momentum.done_today == 12
      assert length(board.columns.done) == 12
      assert board.done_total == 12
      # 13 non-cancelled, 12 done → round(12/13*100) = 92.
      assert board.momentum.pct == 92

      prev = board.cards_by_id["wip"]

      closed =
        Board.card_from_broadcast(
          # newest updated_at → prepended to the head of the done column.
          msg_doc("wip", "Shipped it",
            content: %{"lifecycle_status" => "done"},
            updated_at: now
          ),
          prev,
          all_readable()
        )

      {board, change} = Board.apply_change(board, closed)

      assert change.kind == :closed
      assert change.from_col == :in_progress
      assert change.to_col == :done
      # monotonic +1, never recomputed from the capped column.
      assert board.momentum.done_today == 13
      # the done column stays windowed at 12, the fresh close at its head, and
      # the oldest done card falls off the tail.
      assert length(board.columns.done) == 12
      assert hd(board.columns.done).doc_id == "wip"
      refute Enum.any?(board.columns.done, &(&1.doc_id == "d-12"))
      # done_total counts the FULL uncapped set (13), and pct is derived from it:
      # 13/13 = 100, NOT the capped 12/13 = 92.
      assert board.done_total == 13
      assert board.momentum.pct == 100
    end

    test "a cancelled event removes the card from the columns and bumps cancelled_count" do
      t = ~U[2026-07-07 09:00:00Z]
      board = Board.build([card("in_progress", doc_id: "cx1", updated_at: t)], now: t)

      assert board.cancelled_count == 0
      prev = board.cards_by_id["cx1"]

      cancelled =
        Board.card_from_broadcast(
          msg_doc("cx1", "Abandoned", content: %{"lifecycle_status" => "cancelled"}),
          prev,
          all_readable()
        )

      {board, change} = Board.apply_change(board, cancelled)

      assert change.kind == :cancelled
      assert board.cancelled_count == 1
      assert board.columns.in_progress == []
      refute Map.has_key?(board.cards_by_id, "cx1")
    end
  end

  describe "realtime motion at /admin/projects (wave 2)" do
    setup do
      # a small live corpus the mount snapshot picks up: one claimable + one
      # already in flight.
      task("rt-open", "Claim me", lifecycle: "open", priority: 1)
      task("rt-wip", "Already working", lifecycle: "in_progress", assignee: "studio:doey")
      :ok
    end

    test "a task.claimed event re-buckets the card, climbs in-flight, and flashes it",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/projects")
      assert html =~ "1 in flight"

      send(view.pid, claimed_event("rt-open", "Claim me"))
      html = render(view)

      # the card is now in the in_progress column, in-flight climbed to 2, and
      # the moved card carries the realtime flash marker.
      assert html =~ "2 in flight"
      assert html =~ ~s(data-just-moved)
      assert html =~ ~s(data-doc-id="rt-open")

      # the moved card sits under the in_progress column now.
      assert html =~ ~s(data-col="in_progress" data-doc-id="rt-open")
    end

    test "a task.closed event climbs done-today and flashes the closed card", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/projects")
      assert html =~ "0 done today"

      send(view.pid, closed_event("rt-wip", "Already working"))
      html = render(view)

      assert html =~ "1 done today"
      assert html =~ ~s(data-just-moved)
      # on the deck the closed card lands in the LAST phone — the done ledger.
      [_, ledger] = String.split(html, ~s(data-role="deck-done"), parts: 2)
      assert ledger =~ ~s(data-doc-id="rt-wip")
    end

    test "an unknown non-task event is ignored — no crash, no change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/projects")
      before = render(view)

      # a post document changed, plus a totally unrelated message.
      send(view.pid, {:document_changed, %{type: "post", doc: %{doc_id: "post-1"}}})
      send(view.pid, :some_stray_message)
      after_html = render(view)

      assert Process.alive?(view.pid)
      # the board is untouched — a non-task event never re-buckets anything.
      assert after_html == before
    end

    test "the seen-set drops a repeated event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/projects")

      # process two distinct events; the second sets the live flash on rt-wip.
      send(view.pid, claimed_event("rt-open", "Claim me"))
      _ = render(view)
      send(view.pid, closed_event("rt-wip", "Already working"))
      after_two = render(view)

      # re-send the FIRST event verbatim (same doc_id + updated_at) — it is in
      # the seen-set, so it is dropped: the render is byte-identical (no state
      # change, and the flash does NOT jump back to rt-open).
      send(view.pid, claimed_event("rt-open", "Claim me"))
      after_repeat = render(view)

      assert after_repeat == after_two
    end

    test "the periodic :refresh re-snapshots without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/projects")

      send(view.pid, :refresh)
      html = render(view)

      assert Process.alive?(view.pid)
      # the reconciled snapshot still paints the momentum header.
      assert html =~ ~s(data-role="momentum")
    end

    test "the Done column count reports the FULL total even when the render is windowed",
         %{conn: conn} do
      # 13 done tasks — one past the @done_window (12) — so the rendered pile is
      # capped but the header must still climb (§0 "you always feel progress":
      # closing your 13th task grows Done, it does not freeze at 12).
      for i <- 1..13, do: task("dw-#{i}", "Shipped #{i}", lifecycle: "done")

      {:ok, _view, html} = live(conn, "/admin/projects")

      # exactly 12 done rows render inside the deck's ledger card (the
      # window), but its count pill reports the full 13 (wave 18: Done is the
      # rail's LAST phone card, no longer a column).
      done_cards =
        html
        |> String.split(~s(data-role="deck-done"))
        |> List.last()
        |> String.split(~s(data-role="task-card"))
        |> length()
        |> Kernel.-(1)

      assert done_cards == 12, "the done render is windowed at 12; got #{done_cards}"
      assert done_count(html) == 13, "the Done card count must report the full total"
    end
  end

  describe "Board.restage_plan/4 (pure, wave 3 — the D11 transition table)" do
    test "{open,ready,blocked} -> in_progress is a claim" do
      for from <- [:open, :ready, :blocked] do
        assert Board.restage_plan(from, :in_progress, nil, "studio:admin") == {:claim}
        # a foreign holder is irrelevant to a claim — the claim primitive itself
        # fences a busy card; the plan simply routes to it.
        assert Board.restage_plan(from, :in_progress, "someone", "studio:admin") == {:claim}
      end
    end

    test "the holder's in_progress -> done/blocked is a close with that status" do
      assert Board.restage_plan(:in_progress, :done, "studio:doey", "studio:doey") ==
               {:close, "done"}

      assert Board.restage_plan(:in_progress, :blocked, "studio:doey", "studio:doey") ==
               {:close, "blocked"}
    end

    test "a NON-holder closing an in_progress card is refused (never corrupts the claim)" do
      # close/3 fences on epoch, not identity, so a same-epoch close by a
      # non-holder would corrupt the claim — the plan must refuse BEFORE close.
      assert Board.restage_plan(:in_progress, :done, "studio:someone", "studio:doey") == :refuse

      assert Board.restage_plan(:in_progress, :blocked, "studio:someone", "studio:doey") ==
               :refuse

      # an unclaimed in_progress card (holder nil) is likewise not the worker's.
      assert Board.restage_plan(:in_progress, :done, nil, "studio:doey") == :refuse
    end

    test "the holder's in_progress -> open is a voluntary RELEASE (wave 17)" do
      assert Board.restage_plan(:in_progress, :open, "studio:doey", "studio:doey") ==
               {:release}

      # a non-holder (or an unclaimed lease) never releases someone's work.
      assert Board.restage_plan(:in_progress, :open, "studio:someone", "studio:doey") == :refuse
      assert Board.restage_plan(:in_progress, :open, nil, "studio:doey") == :refuse
    end

    test "ready is a non-drop target, unclaimed->done + done->* refuse" do
      # -> ready (D3, derived column)
      assert Board.restage_plan(:open, :ready, nil, "studio:doey") == :refuse
      # unclaimed open -> done (must claim first)
      assert Board.restage_plan(:open, :done, nil, "studio:doey") == :refuse
      # done -> anything
      assert Board.restage_plan(:done, :in_progress, nil, "studio:doey") == :refuse
      assert Board.restage_plan(:done, :open, nil, "studio:doey") == :refuse
    end
  end

  describe "drag restage write-through at /admin/projects (wave 3, live DB)" do
    # D12: the fenced writes resolve the SAME Default-workspace scope the tasks
    # controller uses, so a persisted live task MUST carry that workspace_id for
    # the fresh-read + claim to find it. A test that flips a persisted row is the
    # only proof this scope is right.
    setup do
      ws = Barkpark.Tenancy.get_default_workspace()
      assert ws, "the Default workspace must be seeded (backfill migration)"
      {:ok, ws: ws}
    end

    test "dropping an open card on In Progress claims it through the fenced primitive",
         %{conn: conn, ws: ws} do
      scoped_task("dr-open", "Claim me by drag", ws.id, lifecycle: "open", priority: 1)

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_hook(view, "restage", %{"doc_id" => "dr-open", "to_col" => "in_progress"})

      # the card re-buckets to in flight in the render (optimistic move — on
      # the deck that is the card's data-col attribute, wave 18)…
      assert html =~ ~s(data-col="in_progress" data-doc-id="dr-open")

      # …and the PERSISTED row actually flipped through the claim primitive.
      doc = Repo.get_by(Document, doc_id: "dr-open")
      assert doc.content["lifecycle_status"] == "in_progress"
      assert get_in(doc.content, ["claim", "worker"]) == "studio:admin"
    end

    test "dropping your own in_progress card on Done closes it (lifecycle flips to done)",
         %{conn: conn, ws: ws} do
      # PDS-D291: a MET criterion, because a DRAG sends no close reason at all
      # and the close-artifact gate refuses a `done` close of a criteria-less row
      # whose reason names no PR+sha. This test is about the drag write-through;
      # the criteria-less drag is its own test, below.
      scoped_task("dr-wip", "Ship it by drag", ws.id,
        lifecycle: "in_progress",
        criteria: [%{"criterion" => "shipped", "met" => true}],
        claim: %{"worker" => "studio:admin", "epoch" => 1}
      )

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_hook(view, "restage", %{"doc_id" => "dr-wip", "to_col" => "done"})

      # dr-wip was the LAST live card, so closing it SETTLES the board (wave
      # 11): the column skeleton gives way to the pipeline-clear state and the
      # card lands in the done ledger instead of a done column.
      assert html =~ ~s(data-role="board-settled")
      assert html =~ ~s(data-doc-id="dr-wip")

      doc = Repo.get_by(Document, doc_id: "dr-wip")
      assert doc.content["lifecycle_status"] == "done"
    end

    # PDS-D291 through the board. A drag carries no reason, so a criteria-less
    # row can NEVER be finished by dragging — and the message has to say that.
    # Before the dedicated clause this fell to the catch-all "its claim moved
    # under you", which names a cause that did not happen and sends the reader
    # to re-claim a lease nobody took.
    test "dragging a CRITERIA-LESS card to Done is refused, and says why",
         %{conn: conn, ws: ws} do
      scoped_task("dr-bare", "No criteria, no artifact", ws.id,
        lifecycle: "in_progress",
        claim: %{"worker" => "studio:admin", "epoch" => 1}
      )

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_hook(view, "restage", %{"doc_id" => "dr-bare", "to_col" => "done"})

      assert html =~ "names no acceptance criteria"
      refute html =~ "its claim moved under you"

      # And the row did NOT move: the optimistic hop rolled back.
      doc = Repo.get_by(Document, doc_id: "dr-bare")
      assert doc.content["lifecycle_status"] == "in_progress"
    end

    test "dropping your own in_progress card on Open RELEASES it (wave 17 unclaim)",
         %{conn: conn, ws: ws} do
      scoped_task("dr-release", "Un-claim me by drag", ws.id,
        lifecycle: "in_progress",
        assignee: "studio:admin",
        claim: %{"worker" => "studio:admin", "epoch" => 7}
      )

      {:ok, view, _html} = live(conn, "/admin/projects")
      _ = render_hook(view, "restage", %{"doc_id" => "dr-release", "to_col" => "open"})

      doc = Repo.get_by(Document, doc_id: "dr-release")
      assert doc.content["lifecycle_status"] == "open"
      assert get_in(doc.content, ["claim", "worker"]) == nil
      assert get_in(doc.content, ["claim", "epoch"]) == 8
      refute Map.has_key?(doc.content, "assignee")
    end

    test "dropping someone ELSE'S in_progress card on Open refuses — never steals the lease",
         %{conn: conn, ws: ws} do
      scoped_task("dr-keep", "Held elsewhere", ws.id,
        lifecycle: "in_progress",
        claim: %{"worker" => "studio:other", "epoch" => 3}
      )

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_hook(view, "restage", %{"doc_id" => "dr-keep", "to_col" => "open"})

      assert html =~ ~s(data-role="notice")
      assert html =~ "only the holder can release"

      doc = Repo.get_by(Document, doc_id: "dr-keep")
      assert doc.content["lifecycle_status"] == "in_progress"
      assert get_in(doc.content, ["claim", "worker"]) == "studio:other"
    end

    test "dropping your own in_progress card on Blocked parks it (lifecycle flips to blocked)",
         %{conn: conn, ws: ws} do
      scoped_task("dr-park", "Park it by drag", ws.id,
        lifecycle: "in_progress",
        claim: %{"worker" => "studio:admin", "epoch" => 4}
      )

      {:ok, view, _html} = live(conn, "/admin/projects")
      _ = render_hook(view, "restage", %{"doc_id" => "dr-park", "to_col" => "blocked"})

      doc = Repo.get_by(Document, doc_id: "dr-park")
      assert doc.content["lifecycle_status"] == "blocked"
    end

    test "a card another worker holds REFUSES the drop — the claim is never corrupted",
         %{conn: conn, ws: ws} do
      scoped_task("dr-foreign", "Held by someone else", ws.id,
        lifecycle: "in_progress",
        claim: %{"worker" => "studio:someone-else", "epoch" => 9}
      )

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_hook(view, "restage", %{"doc_id" => "dr-foreign", "to_col" => "done"})

      # a dismissible refusal notice appears…
      assert html =~ ~s(data-role="notice")
      # …and the persisted row is UNTOUCHED — same holder, same epoch, still WIP.
      doc = Repo.get_by(Document, doc_id: "dr-foreign")
      assert doc.content["lifecycle_status"] == "in_progress"
      assert get_in(doc.content, ["claim", "worker"]) == "studio:someone-else"
      assert get_in(doc.content, ["claim", "epoch"]) == 9
    end

    test "Ready is a non-drop target — a drop there refuses with no write",
         %{conn: conn, ws: ws} do
      scoped_task("dr-ready", "Ready to go", ws.id, lifecycle: "open", priority: 1)

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_hook(view, "restage", %{"doc_id" => "dr-ready", "to_col" => "ready"})

      assert html =~ ~s(data-role="notice")
      doc = Repo.get_by(Document, doc_id: "dr-ready")
      assert doc.content["lifecycle_status"] == "open"
      refute Map.has_key?(doc.content, "claim")
    end

    test "the refusal notice is dismissible", %{conn: conn, ws: ws} do
      scoped_task("dr-dismiss", "Ready to go", ws.id, lifecycle: "open", priority: 1)

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_hook(view, "restage", %{"doc_id" => "dr-dismiss", "to_col" => "ready"})
      assert html =~ ~s(data-role="notice")

      html = render_click(view, "dismiss-notice", %{})
      refute html =~ ~s(data-role="notice")
    end

    test "the grouped kanban still opts into the drag hook with draggable cards",
         %{conn: conn, ws: ws} do
      scoped_task("dr-hook", "Anything", ws.id, lifecycle: "open")

      # wave 18: the flat deck has no drop targets (click = peek); the drag
      # surface lives on the grouped/filtered kanban drill-down.
      {:ok, _view, html} = live(conn, "/admin/projects?group=goal")
      assert html =~ ~s(phx-hook="BarkparkBoardDrag")
      assert html =~ ~s(draggable="true")

      {:ok, _view, flat} = live(conn, "/admin/projects")
      refute flat =~ ~s(phx-hook="BarkparkBoardDrag")
    end
  end

  describe "Board group/filter facets (pure, wave 4)" do
    test "group_keys are none/goal/priority/label" do
      assert Board.group_keys() == [:none, :goal, :priority, :label]
    end

    test "facets are the DISTINCT, sorted values actually present in the board" do
      now = ~U[2026-07-07 12:00:00Z]

      board =
        Board.build(
          [
            card("open",
              doc_id: "f1",
              parent_id: "epic-b",
              priority: 2,
              labels: ["y", "x"],
              worker: "w2"
            ),
            card("open",
              doc_id: "f2",
              parent_id: "epic-a",
              priority: 0,
              labels: ["y"],
              worker: "w1"
            ),
            card("done", doc_id: "f3", updated_at: now)
          ],
          now: now
        )

      f = Board.facets(board)

      assert f.goals == ["epic-a", "epic-b"]
      # priorities are strings, numeric-sorted (0 before 2).
      assert f.priorities == ["0", "2"]
      # labels flattened + deduped + sorted; the empty done card contributes none.
      assert f.labels == ["x", "y"]
      assert f.workers == ["w1", "w2"]
    end

    test "card_matches? ANDs facets and intersects the multi-valued label set" do
      c = card("open", parent_id: "epic-a", priority: 2, labels: ["x", "y"], worker: "w1")

      # [] / missing facet is unconstrained.
      assert Board.card_matches?(c, %{})
      assert Board.card_matches?(c, %{goal: [], priority: [], label: [], worker: []})

      assert Board.card_matches?(c, %{goal: ["epic-a"]})
      refute Board.card_matches?(c, %{goal: ["epic-b"]})
      assert Board.card_matches?(c, %{priority: ["2"]})
      refute Board.card_matches?(c, %{priority: ["3"]})
      # label facet = intersection: the card's {x,y} meets {y,z}.
      assert Board.card_matches?(c, %{label: ["y", "z"]})
      refute Board.card_matches?(c, %{label: ["z"]})
      # facets AND together.
      assert Board.card_matches?(c, %{goal: ["epic-a"], worker: ["w1"]})
      refute Board.card_matches?(c, %{goal: ["epic-a"], worker: ["w2"]})
    end
  end

  describe "Board.view/2 (pure, wave 4)" do
    test "group_by :none with no filters is the family view — parentless corpus folds 1:1" do
      now = ~U[2026-07-07 12:00:00Z]

      board =
        Board.build(
          [
            card("in_progress", doc_id: "v1", updated_at: now),
            card("open", doc_id: "v2", blocker_statuses: ["in_progress"], updated_at: now),
            card("done", doc_id: "v3", updated_at: now)
          ],
          now: now
        )

      v = Board.view(board, now: now)

      refute v.grouped?
      refute v.filtered?
      assert v.family?
      assert length(v.lanes) == 1
      lane = hd(v.lanes)
      # a corpus with NO parent links folds 1:1 — same buckets, every card a
      # childless family root (family: nil), placement unchanged.
      strip = fn cols ->
        Map.new(cols, fn {k, cs} -> {k, Enum.map(cs, &Map.delete(&1, :family))} end)
      end

      assert strip.(lane.columns) == board.columns
      assert lane.done_total == board.done_total
      assert lane.counts[:done] == board.done_total
      # momentum is board.momentum UNCHANGED (D13) — always task-level.
      assert v.momentum == board.momentum
    end

    test "the family view folds children into their root's card and escalates by activity" do
      now = ~U[2026-07-07 12:00:00Z]

      board =
        Board.build(
          [
            card("open", doc_id: "epic", title: "The epic", updated_at: now),
            card("in_progress",
              doc_id: "kid-a",
              parent_id: "epic",
              title: "Kid A",
              worker: "w1",
              updated_at: now
            ),
            card("done", doc_id: "kid-b", parent_id: "epic", title: "Kid B", updated_at: now),
            card("open",
              doc_id: "grandkid",
              parent_id: "kid-a",
              title: "Grandkid",
              updated_at: now
            ),
            card("open", doc_id: "loner", title: "Loner", updated_at: now),
            card("done",
              doc_id: "kid-of-ghost",
              parent_id: "no-such-parent",
              title: "Orphan",
              updated_at: now
            )
          ],
          now: now
        )

      v = Board.view(board, now: now)
      lane = hd(v.lanes)
      ids = fn col -> Enum.map(lane.columns[col], & &1.doc_id) end

      # children never render as their own cards — ONE card per family…
      assert "kid-a" not in ids.(:in_progress) and "kid-a" not in ids.(:open)
      assert "kid-b" not in ids.(:done)
      # …the open epic ESCALATES to in_progress (a descendant is in flight)…
      assert "epic" in ids.(:in_progress)
      epic = Enum.find(lane.columns[:in_progress], &(&1.doc_id == "epic"))
      # …its own state stays honest on an escalated card (open + no blockers
      # derives READY, and that stays its glyph/color even in in_progress)…
      assert epic.color_role == :ready
      # …and the card carries the family: subtree stats + in-flight-first rows.
      assert epic.family.stats == %{total: 3, done: 1, in_flight: 1}

      assert [
               %{doc_id: "kid-a", depth: 1},
               %{doc_id: "grandkid", depth: 2},
               %{doc_id: "kid-b", depth: 1}
             ] =
               Enum.map(epic.family.rows, &Map.take(&1, [:doc_id, :depth]))

      # an orphan (parent not on the board) is its OWN root, never hidden.
      assert "kid-of-ghost" in ids.(:done)
      # done_total counts done ROOTS (kid-of-ghost), not done children.
      assert lane.done_total == 1
      # childless roots stay put (open + no blockers ⇒ the ready overlay).
      assert "loner" in ids.(:ready)
      # momentum is still TASK-level: kid-a keeps in_flight honest.
      assert v.momentum.in_flight == 1
    end

    test "group_by :goal partitions into sorted swimlanes with the none-lane last" do
      now = ~U[2026-07-07 12:00:00Z]

      board =
        Board.build(
          [
            card("in_progress", doc_id: "g1", parent_id: "epic-b", updated_at: now),
            card("in_progress", doc_id: "g2", parent_id: "epic-a", updated_at: now),
            card("in_progress", doc_id: "g3", updated_at: now)
          ],
          now: now
        )

      v = Board.view(board, group_by: :goal, now: now)

      assert v.grouped?
      assert Enum.map(v.lanes, & &1.label) == ["↳epic-a", "↳epic-b", "none"]
      # each lane holds exactly its one card in the in_progress column.
      for lane <- v.lanes, do: assert(length(lane.columns.in_progress) == 1)
    end

    test "group_by :priority orders lanes numerically (P0 before P2), none last" do
      now = ~U[2026-07-07 12:00:00Z]

      board =
        Board.build(
          [
            card("in_progress", doc_id: "p2", priority: 2, updated_at: now),
            card("in_progress", doc_id: "p0", priority: 0, updated_at: now),
            card("in_progress", doc_id: "pnil", updated_at: now)
          ],
          now: now
        )

      v = Board.view(board, group_by: :priority, now: now)
      assert Enum.map(v.lanes, & &1.label) == ["P0", "P2", "none"]
    end

    test "group_by :label places a multi-label card in EACH of its lanes" do
      now = ~U[2026-07-07 12:00:00Z]

      board =
        Board.build([card("in_progress", doc_id: "ml", labels: ["a", "b"], updated_at: now)],
          now: now
        )

      v = Board.view(board, group_by: :label, now: now)

      assert Enum.sort(Enum.map(v.lanes, & &1.label)) == ["#a", "#b"]

      for lane <- v.lanes do
        assert Enum.any?(lane.columns.in_progress, &(&1.doc_id == "ml"))
      end
    end

    test "MOMENTUM HONESTY (D13): grouping alone preserves momentum; a filter recomputes it" do
      now = ~U[2026-07-07 12:00:00Z]

      board =
        Board.build(
          [
            card("in_progress", doc_id: "m1", worker: "w1", updated_at: now),
            card("in_progress", doc_id: "m2", worker: "w2", updated_at: now),
            card("done", doc_id: "m3", updated_at: now)
          ],
          now: now
        )

      # grouped but UNFILTERED → momentum is board.momentum verbatim.
      assert Board.view(board, group_by: :priority, now: now).momentum == board.momentum

      # filtered to w1 → only m1 survives: 1 in flight, 0 done → pct 0.
      v = Board.view(board, filters: %{worker: ["w1"]}, now: now)
      assert v.filtered?
      assert v.momentum.in_flight == 1
      assert v.momentum.done_today == 0
      assert v.momentum.pct == 0
    end

    test "each lane's done sub-column is windowed at @done_window with an honest done_total" do
      now = ~U[2026-07-07 12:00:00Z]

      done_cards =
        for i <- 1..13 do
          card("done",
            doc_id: "gd-#{i}",
            parent_id: "epic-x",
            updated_at: DateTime.add(now, -i * 60, :second)
          )
        end

      board = Board.build(done_cards, now: now)
      v = Board.view(board, group_by: :goal, now: now)

      lane = Enum.find(v.lanes, &(&1.label == "↳epic-x"))
      assert length(lane.columns.done) == 12
      assert lane.done_total == 13
      assert lane.counts[:done] == 13
    end

    test "view.empty? is true when a filter matches nothing" do
      now = ~U[2026-07-07 12:00:00Z]
      board = Board.build([card("open", doc_id: "e1", worker: "w1", updated_at: now)], now: now)

      v = Board.view(board, filters: %{worker: ["nobody"]}, now: now)
      assert v.empty?
      assert v.filtered?
    end
  end

  describe "group/filter controls at /admin/projects (wave 4, live)" do
    test "the controls render a group selector + facet chips from the REAL corpus", %{conn: conn} do
      task("cf1", "Wire the mirror",
        lifecycle: "in_progress",
        priority: 1,
        parent_id: "epic-9",
        labels: ["proj:board"],
        assignee: "studio:doey"
      )

      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ ~s(data-role="controls")
      assert html =~ ~s(data-role="group-select")
      assert html =~ ~s(data-role="facet-goal")
      assert html =~ ~s(data-role="facet-priority")
      assert html =~ ~s(data-role="facet-label")
      assert html =~ ~s(data-role="facet-worker")
      # the chips carry the real values, prefixed.
      assert html =~ "↳epic-9"
      assert html =~ "#proj:board"
      assert html =~ "@studio:doey"
    end

    test "toggling a worker chip narrows the board and marks the chip active", %{conn: conn} do
      task("nd", "Doey ships it", lifecycle: "in_progress", assignee: "studio:doey")
      task("na", "Agent ships it", lifecycle: "in_progress", assignee: "studio:agent")

      {:ok, view, html} = live(conn, "/admin/projects")
      assert html =~ "Doey ships it"
      assert html =~ "Agent ships it"

      html = render_click(view, "toggle-filter", %{"facet" => "worker", "value" => "studio:doey"})

      assert html =~ "Doey ships it"
      refute html =~ "Agent ships it"
      # the active facet chip carries .is-active (the group None chip has an extra
      # class between, so this substring matches only an active FACET chip).
      assert html =~ ~s(bp-chip is-active)
    end

    test "the group selector renders swimlanes with labels", %{conn: conn} do
      task("sw-a", "Alpha work",
        lifecycle: "in_progress",
        parent_id: "epic-a",
        assignee: "studio:x"
      )

      task("sw-b", "Beta work",
        lifecycle: "in_progress",
        parent_id: "epic-b",
        assignee: "studio:y"
      )

      {:ok, view, _html} = live(conn, "/admin/projects")
      html = render_click(view, "set-group", %{"group" => "goal"})

      assert html =~ ~s(data-role="lane")
      assert html =~ ~s(data-role="lane-label")
      assert html =~ "↳epic-a"
      assert html =~ "↳epic-b"
      # both cards still on the board, now under their lanes.
      assert html =~ "Alpha work"
      assert html =~ "Beta work"
    end

    test "an over-narrow filter shows the honest filtered-empty state + clear-all", %{conn: conn} do
      task("fe1", "The only task", lifecycle: "open", assignee: "studio:doey")

      {:ok, view, _html} = live(conn, "/admin/projects")

      html =
        render_click(view, "toggle-filter", %{"facet" => "worker", "value" => "studio:ghost"})

      assert html =~ ~s(data-role="filtered-empty")
      assert html =~ "No tasks match"
      assert html =~ ~s(data-role="clear-all")
      # distinct from the board-empty copy (the board is NOT empty).
      refute html =~ ~s(data-role="board-empty")

      # clear-all restores the whole board.
      html = render_click(view, "clear-filters", %{})
      refute html =~ ~s(data-role="filtered-empty")
      assert html =~ "The only task"
    end

    test "a ?group=goal URL renders swimlanes on mount (shareable)", %{conn: conn} do
      task("url-g", "Goal-scoped",
        lifecycle: "in_progress",
        parent_id: "epic-a",
        assignee: "studio:x"
      )

      {:ok, _view, html} = live(conn, "/admin/projects?group=goal")
      assert html =~ ~s(data-role="lane")
      assert html =~ "↳epic-a"
    end

    test "a ?worker= URL filters on mount (shareable), unknown group falls back to none",
         %{conn: conn} do
      task("uf-a", "Ada task", lifecycle: "in_progress", assignee: "studio:ada")
      task("uf-b", "Bpp task", lifecycle: "in_progress", assignee: "studio:bpp")

      {:ok, _view, html} = live(conn, "/admin/projects?worker=studio:ada&group=evil")

      # the worker filter applied…
      assert html =~ "Ada task"
      refute html =~ "Bpp task"
      # …and the bogus group whitelisted to :none — no swimlane chrome, no crash.
      refute html =~ ~s(data-role="lane-label")
    end
  end

  describe "filters fold so the board is the hero (w6-reveal)" do
    test "facets live INSIDE a filter disclosure that is collapsed by default", %{conn: conn} do
      # A corpus with facet values that, uncapped, would wall the board.
      for i <- 1..30,
          do:
            task("wall-#{i}", "Task #{i}",
              lifecycle: "open",
              labels: ["l#{i}"],
              assignee: "w#{i}"
            )

      {:ok, _view, html} = live(conn, "/admin/projects")

      # the disclosure wraps the facets and is CLOSED on a plain load…
      assert html =~ ~s(data-role="filters")
      assert html =~ ~s(data-role="filters-toggle")
      refute html =~ ~s(data-role="filters" open)
      # …yet the facet markup is still in the DOM (present, just folded)…
      assert html =~ ~s(data-role="facet-label")
      assert html =~ ~s(data-role="facet-worker")
      # …and the DECK renders (the work, not a filter wall, is the hero).
      assert html =~ ~s(data-role="deck")
      assert html =~ ~s(data-role="task-card")
    end

    test "arriving pre-filtered opens the disclosure so active chips are visible", %{conn: conn} do
      task("pf-a", "Ada task", lifecycle: "in_progress", assignee: "studio:ada")
      task("pf-b", "Bpp task", lifecycle: "in_progress", assignee: "studio:bpp")

      {:ok, _view, html} = live(conn, "/admin/projects?worker=studio:ada")

      # the filter is active → the disclosure is open, and flags itself active.
      assert html =~ ~s(data-role="filters" open)
      assert html =~ ~s(data-role="filters-active")
    end

    test "no facets at all → no filter chrome", %{conn: conn} do
      # an empty board has nothing to filter.
      {:ok, _view, html} = live(conn, "/admin/projects")
      refute html =~ ~s(data-role="filters")
      assert html =~ ~s(data-role="board-empty")
    end
  end

  describe "focus & lineage (wave 12)" do
    setup do
      task("epic-x", "Ship the epic", lifecycle: "in_progress", assignee: "lead")
      task("ex-c1", "Design the schema", lifecycle: "done", parent_id: "epic-x")

      task("ex-c2", "Wire the resolver",
        lifecycle: "in_progress",
        parent_id: "epic-x",
        assignee: "studio:doey"
      )

      task("ex-c3", "Write the docs", lifecycle: "open", parent_id: "epic-x")

      task("solo-w", "Solo in flight",
        lifecycle: "in_progress",
        assignee: "lead",
        criteria: [
          %{"criterion" => "compile the parser", "met" => true},
          %{"criterion" => "green the golden tests", "met" => false}
        ]
      )

      task("ready-p", "Parent merely ready", lifecycle: "open")
      task("rp-c1", "Child of ready parent", lifecycle: "done", parent_id: "ready-p")
      :ok
    end

    test "an in-flight parent shows its subtask tally and the active child as focus",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ ~s(data-role="subtasks")
      assert html =~ "1/3 sub"
      assert html =~ ~s(data-role="focus")
      assert html =~ "Wire the resolver"
      assert html =~ "@studio:doey"
    end

    test "an in-flight card without children focuses its first unmet criterion",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ "green the golden tests"
      # the full checklist shows BOTH criteria (wave 20)…
      assert html =~ ~s(data-role="card-criteria")
      assert html =~ "compile the parser"
      # …but a MET criterion is never the NOW focus.
      [_, focus] = String.split(html, ~s(data-role="focus"), parts: 2)
      focus = focus |> String.split("</p>", parts: 2) |> hd()
      assert focus =~ "green the golden tests"
      refute focus =~ "compile the parser"
    end

    test "a child never duplicates as its own board card — it rides the family row",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      # ex-c2 is in flight under epic-x: NO standalone card…
      refute html =~
               ~s(<article class="bp-card" data-role="task-card" data-col="in_progress" data-doc-id="ex-c2")

      refute html =~ ~s(data-role="task-card"
          data-col="in_progress"
          data-doc-id="ex-c2")

      # …but exactly one family row inside the epic's card carries it.
      assert html =~ ~s(data-role="family-row")
      [_, fam] = String.split(html, ~s(data-role="family"), parts: 2)
      assert fam =~ ~s(data-doc-id="ex-c2")
      assert fam =~ "Wire the resolver"
    end

    test "lineage shows everywhere; family rows supersede the focus line",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      # the ready parent still carries its lineage pill…
      assert html =~ "1/1 sub"
      # …the epic's activity now lives in its FAMILY rows (wave 16) — the
      # in-flight child renders inside the epic card with its worker…
      assert html =~ ~s(data-role="family")
      assert html =~ ~s(data-role="family-row")
      # …so only the childless in-flight card (solo-w) keeps a NOW focus line
      # (its unmet criterion; a family card never doubles the same signal).
      assert occurrences(html, ~s(data-role="focus")) == 1
    end
  end

  describe "task peek (wave 13)" do
    setup do
      w =
        task("pk-epic", "Peek epic",
          lifecycle: "in_progress",
          description: "The long body of the epic.",
          purpose: %{
            "statement" => "Make task inspection trustworthy",
            "why" => "Operators need the reason before implementation prose",
            "endgame" => "Every task explains its contribution",
            "importance" => %{"score" => 94, "reason" => "core planning signal"},
            "relevance" => %{"score" => 97, "reason" => "active reader work"},
            "proof" => [
              %{
                "claim" => "Reader contract",
                "evidence" => "criteria renders first",
                "source" => "board test"
              }
            ]
          },
          claim: %{
            "worker" => "studio:kalle",
            "epoch" => 3,
            "ts_iso" => DateTime.utc_now() |> DateTime.add(-7200) |> DateTime.to_iso8601()
          },
          criteria: [
            %{
              "criterion" => "solver behind a flag",
              "met" => true,
              "evidence" => "PR #1421 merged"
            },
            %{"criterion" => "goldens byte-identical", "met" => false}
          ]
        )

      _child =
        task("pk-child", "Peek child",
          lifecycle: "in_progress",
          parent_id: "pk-epic",
          assignee: "studio:doey"
        )

      blocker = task("pk-blocker", "The blocking task", lifecycle: "open")
      Repo.insert!(%Edge{from_id: w.id, to_id: blocker.id, kind: "blocks"})
      :ok
    end

    test "an in-flight card greets you expanded; details opens the inspector",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/projects")

      # wave 23: pk-epic is in flight, so the gantt is ALREADY open on load.
      assert html =~ ~s(data-role="gantt")

      view |> element(~s{[data-role="expand-details"]}) |> render_click()

      assert_patch(view, "/admin/projects?task=pk-epic")
      html = render(view)

      assert html =~ ~s(data-role="peek")
      assert html =~ ~s(data-role="peek-title")
      assert html =~ "Peek epic"
      # claim lease
      assert html =~ ~s(data-role="peek-claim")
      assert html =~ "studio:kalle"
      assert html =~ "epoch 3"
      # description + criteria with close-time evidence
      assert html =~ "The long body of the epic."
      assert html =~ "solver behind a flag"
      assert html =~ "goldens byte-identical"
      assert html =~ ~s(data-role="peek-evidence")
      assert html =~ "PR #1421 merged"
      assert html =~ ~s(data-role="peek-purpose")
      assert html =~ "Make task inspection trustworthy"
      assert html =~ "94/100"
      assert html =~ ~s(data-role="peek-purpose-proof")
      assert html =~ "criteria renders first"

      {criteria_at, _} = :binary.match(html, ~s(data-role="peek-criteria"))
      {purpose_at, _} = :binary.match(html, ~s(data-role="peek-purpose"))
      {description_at, _} = :binary.match(html, ~s(data-role="peek-description"))
      assert criteria_at < purpose_at
      assert purpose_at < description_at
      # lineage both ways — the child sits in the family tree, the blocker in
      # its own section
      assert html =~ ~s(data-role="peek-tree")
      assert html =~ ~s(data-doc-id="pk-child")
      assert html =~ "Peek child"
      assert html =~ ~s(data-role="peek-blocker")
      assert html =~ "The blocking task"
    end

    test "a shared ?task= URL opens the peek directly", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=pk-epic")

      assert html =~ ~s(data-role="peek")
      assert html =~ "Peek epic"
    end

    test "a sparse task gets intentional criteria and purpose fallbacks", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=pk-child")

      assert html =~ "No acceptance criteria recorded — completion cannot be verified."
      assert html =~ "Peek epic"
      assert html =~ "Why this task is necessary to achieve Peek epic is not recorded"
      assert html =~ "Advance Peek epic by completing this task"
      refute html =~ "Barkpark mission"
      refute html =~ "A completed, evidence-backed Barkpark outcome"
    end

    test "close patches back to the bare board", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/projects?task=pk-epic")

      view |> element(~s{[data-role="peek-close"]}) |> render_click()

      assert_patch(view, "/admin/projects")
      refute render(view) =~ ~s(data-role="peek")
    end

    test "hopping to a child re-peeks in place", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/projects?task=pk-epic")

      view
      |> element(~s{li[data-doc-id="pk-child"] [data-role="tree-hop"]})
      |> render_click()

      assert_patch(view, "/admin/projects?task=pk-child")
      assert render(view) =~ "Peek child"
    end

    test "an unknown task id peeks nothing and never crashes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=no-such-task")

      refute html =~ ~s(data-role="peek")
      assert html =~ ~s(data-role="deck")
    end

    test "changing the grouping preserves the open peek", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/projects?task=pk-epic")

      view |> element(~s{[data-role="group-option"][data-group="goal"]}) |> render_click()

      assert_patch(view, "/admin/projects?group=goal&task=pk-epic")
      assert render(view) =~ "Peek epic"
    end
  end

  describe "peek field-visibility seal (Envelope gate)" do
    # The board mount is UNGATED — it renders the peek to any admin board viewer.
    # The peek hand-picks content fields straight off the raw doc, so without the
    # Envelope cross-check a schema-declared PRIVATE field leaks. Seed a `task`
    # schema (the SAME one `tasks/query.ex` resolves via `Content.get_schema/3`)
    # that marks two hand-picked peek fields private, plus a doc carrying them.
    setup do
      {:ok, _schema} =
        Barkpark.Content.upsert_schema(
          %{
            "name" => "task",
            "title" => "Task",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "description",
                "title" => "Body",
                "type" => "text",
                "visibility" => "private"
              },
              %{
                "name" => "acceptance_criteria",
                "title" => "Criteria",
                "type" => "array",
                "visibility" => "private"
              }
            ]
          },
          "production"
        )

      task("sec-task", "Sealed task",
        lifecycle: "in_progress",
        description: "SECRET-BODY-should-not-leak",
        criteria: [
          %{"criterion" => "SECRET-CRITERION", "met" => true, "evidence" => "SECRET-EVIDENCE"}
        ]
      )

      :ok
    end

    test "a peek field the schema marks private is OMITTED for the ungated board viewer",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=sec-task")

      # The peek opens and the always-public title still renders...
      assert html =~ ~s(data-role="peek")
      assert html =~ "Sealed task"

      # ...but every PEEK private field is redacted to its empty value, so the
      # panel sections that project it never render: `@peek.description` gated to
      # nil drops `:if={@peek.description || @peek.design_doc}`, and
      # `@peek.criteria` gated to `[]` drops `:if={@peek.criteria != []}` (and
      # with it every `peek-criterion` / `peek-evidence` row). No empty shell
      # hints the hidden field exists. Removing the Envelope gate makes these
      # peek sections reappear — the mutation that proves this test bites.
      refute html =~ ~s(data-role="peek-description")
      refute html =~ ~s(data-role="peek-criteria")
      refute html =~ ~s(data-role="peek-criterion")
      refute html =~ ~s(data-role="peek-evidence")

      # NOTE (sibling now sealed): the same private `description` /
      # `acceptance_criteria` values were ALSO leaking via the deck card
      # (`card-desc`, `card-criteria`) and the gantt (`gantt-criteria`) off the
      # SEPARATE `Board.snapshot` list-card reads. That sibling bypass is now
      # sealed at `Board.to_card/4` (felix W18, task-felix-w13-boardsnapshot-fieldvis-seal)
      # and proven by the "deck card + gantt field-visibility seal" describe
      # below (and `board_test.exs`). These peek assertions stay scoped to the
      # peek surface.
    end

    test "a peek field with NO visibility declaration stays public (legacy parity)",
         %{conn: conn} do
      # `labels` is undeclared in the seeded schema ⇒ `field_readable?` true ⇒ the
      # gate is selective, not a blanket redaction of every peek field.
      task("sec-labeled", "Labeled task", lifecycle: "open", labels: ["urgent-label"])

      {:ok, _view, html} = live(conn, "/admin/projects?task=sec-labeled")

      assert html =~ ~s(data-role="peek")
      assert html =~ "urgent-label"
    end
  end

  describe "deck card + gantt field-visibility seal (Board.snapshot Envelope gate)" do
    # SIBLING of the peek seal: `Board.snapshot`'s `to_card/4` hand-picks the
    # same content fields for the DECK CARD (and, through the derived family
    # rows, the GANTT). Seed a `task` schema marking `description` +
    # `acceptance_criteria` private plus an in_progress doc carrying them; the
    # rendered board must never paint the private text on the card or in the
    # gantt. Mutation: strip the `if(readable?...)` gate from `to_card/4` and
    # the SECRET strings reappear → these refutes go RED.
    setup do
      {:ok, _schema} =
        Barkpark.Content.upsert_schema(
          %{
            "name" => "task",
            "title" => "Task",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "description",
                "title" => "Body",
                "type" => "text",
                "visibility" => "private"
              },
              %{
                "name" => "acceptance_criteria",
                "title" => "Criteria",
                "type" => "array",
                "visibility" => "private"
              }
            ]
          },
          "production"
        )

      task("deck-sec", "Sealed board task",
        lifecycle: "in_progress",
        description: "SECRET-DECK-BODY-should-not-leak",
        criteria: [%{"criterion" => "SECRET-DECK-CRITERION", "met" => false, "evidence" => ""}]
      )

      :ok
    end

    test "the deck card + gantt OMIT a schema-private field for the board viewer",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      # The always-public title still paints the card...
      assert html =~ "Sealed board task"

      # ...but the private text never reaches the deck card (`card-desc` /
      # `card-criteria`) NOR the expanded in-flight gantt (`gantt-criteria`).
      refute html =~ "SECRET-DECK-BODY-should-not-leak"
      refute html =~ "SECRET-DECK-CRITERION"
      refute html =~ ~s(data-role="card-desc")
      refute html =~ ~s(data-role="card-criteria")
      refute html =~ ~s(data-role="gantt-criteria")
    end
  end

  describe "realtime broadcast field-visibility seal (card_from_broadcast/3 Envelope gate)" do
    # SIBLING of the snapshot deck seal, but on the REALTIME path: the mount
    # computes `readable?` from the seeded `task` schema and threads it into
    # `card_from_broadcast/3`, so a live `{:document_changed}` event carrying a
    # schema-private field NEVER paints it on the deck card (or the gantt). The
    # SECRET arrives ONLY via the broadcast (the seeded doc is benign) so this
    # isolates the realtime seal from the snapshot one.
    #
    # MUTATION (proves the refutes bite): unthread the predicate at board_live.ex
    # L272 — pass a permissive `fn _ -> true end` instead of
    # `socket.assigns.readable?` — and the SECRET strings reappear on the card →
    # these refutes go RED.
    setup do
      {:ok, _schema} =
        Barkpark.Content.upsert_schema(
          %{
            "name" => "task",
            "title" => "Task",
            "visibility" => "public",
            "fields" => [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{
                "name" => "description",
                "title" => "Body",
                "type" => "text",
                "visibility" => "private"
              },
              %{
                "name" => "acceptance_criteria",
                "title" => "Criteria",
                "type" => "array",
                "visibility" => "private"
              }
            ]
          },
          "production"
        )

      # A benign in_progress card the mount snapshot picks up — no private text
      # yet; the SECRET arrives only through the broadcast below.
      task("rt-sec", "Realtime sealed", lifecycle: "in_progress", assignee: "studio:doey")

      :ok
    end

    test "a broadcast carrying schema-private description/criteria is redacted on the deck card",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/projects")
      assert html =~ "Realtime sealed"

      # A live event mutates the card to carry the schema-private fields.
      send(
        view.pid,
        task_event(
          "rt-sec",
          "Realtime sealed",
          "task.updated",
          %{
            "lifecycle_status" => "in_progress",
            "assignee" => "studio:doey",
            "description" => "SECRET-RT-BODY-should-not-leak",
            "acceptance_criteria" => [
              %{"criterion" => "SECRET-RT-CRITERION", "met" => false, "evidence" => ""}
            ]
          },
          ~U[2026-07-08 09:00:00Z]
        )
      )

      html = render(view)

      # the always-public title still paints…
      assert html =~ "Realtime sealed"

      # …but the schema-private text never reaches the deck card (`card-desc` /
      # `card-criteria`) NOR the expanded in-flight gantt (`gantt-criteria`).
      refute html =~ "SECRET-RT-BODY-should-not-leak"
      refute html =~ "SECRET-RT-CRITERION"
      refute html =~ ~s(data-role="card-desc")
      refute html =~ ~s(data-role="card-criteria")
      refute html =~ ~s(data-role="gantt-criteria")
    end
  end

  describe "peek context & insight (wave 14)" do
    setup do
      task("ctx-grand", "Grand goal", lifecycle: "open")
      task("ctx-mid", "Mid parent", lifecycle: "open", parent_id: "ctx-grand")

      t =
        task("ctx-task", "The focused task",
          lifecycle: "in_progress",
          parent_id: "ctx-mid",
          assignee: "w-hist"
        )

      task("ctx-c1", "Direct child", lifecycle: "open", parent_id: "ctx-task")
      task("ctx-g1", "Grandchild shipped", lifecycle: "done", parent_id: "ctx-c1")
      task("ctx-sib", "Sibling of the task", lifecycle: "open", parent_id: "ctx-mid")
      task("ctx-aunt", "Sibling of the parent", lifecycle: "open", parent_id: "ctx-grand")

      dependent = task("ctx-dep", "Waiting dependent", lifecycle: "blocked")
      Repo.insert!(%Edge{from_id: dependent.id, to_id: t.id, kind: "blocks"})

      Repo.insert!(%MutationEvent{
        dataset: "production",
        type: "task",
        doc_id: "ctx-task",
        mutation: "task.claimed",
        rev: "r-ev-1",
        document: %{"content" => %{"claim" => %{"worker" => "w-hist"}}},
        inserted_at: DateTime.utc_now()
      })

      :ok
    end

    test "the family tree shows ancestors, siblings, the parent's siblings, and grandchildren",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/projects?task=ctx-task")

      # scope to the tree section (every title also exists as a board card)
      [_, tree] = String.split(html, ~s(data-role="peek-tree"), parts: 2)
      tree = tree |> String.split("</section>", parts: 2) |> hd()

      # the whole family is present…
      assert tree =~ "Grand goal"
      assert tree =~ "Mid parent"
      assert tree =~ "Sibling of the task"
      assert tree =~ "Sibling of the parent"
      assert tree =~ "The focused task"
      assert tree =~ "Direct child"
      assert tree =~ "Grandchild shipped"

      # …root-first down the spine, and the focused row is marked.
      {grand_at, _} = :binary.match(tree, "Grand goal")
      {mid_at, _} = :binary.match(tree, "Mid parent")
      {self_at, _} = :binary.match(tree, "The focused task")
      assert grand_at < mid_at and mid_at < self_at
      assert tree =~ "this task"

      # an ancestor row hops to re-peek it.
      view
      |> element(~s{li[data-doc-id="ctx-grand"] [data-role="tree-hop"]})
      |> render_click()

      assert_patch(view, "/admin/projects?task=ctx-grand")
      assert render(view) =~ "Grand goal"
    end

    test "the subtasks header rolls up the FULL subtree, not just direct children",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=ctx-task")

      # direct: 1 child, 0 done · subtree: child + grandchild, 1 done.
      assert html =~ ~s(data-role="peek-subtree")
      assert html =~ "subtree 1/2"
    end

    test "the Blocks section lists the reverse dependencies (the impact read)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=ctx-task")

      assert html =~ ~s(data-role="peek-blocks")
      assert html =~ "Waiting dependent"
    end

    test "the Activity log renders the durable history plus the created stamp",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=ctx-task")

      assert html =~ ~s(data-role="peek-activity")
      assert html =~ ~s(data-role="peek-event")
      assert html =~ "claimed"
      assert html =~ "@w-hist"
      assert html =~ ~s(data-role="peek-created")
    end

    test "derived Why identifies missing goal rationale instead of restating criteria",
         %{conn: conn} do
      task("ctx-rationale", "A task with a completion contract",
        lifecycle: "open",
        parent_id: "ctx-mid",
        criteria: [%{"criterion" => "The check passes", "met" => false}]
      )

      {:ok, _view, html} = live(conn, "/admin/projects?task=ctx-rationale")

      assert html =~
               "Why this task is necessary for Mid parent within Grand goal is not recorded"

      refute html =~ "acceptance criteria define the required outcome"
    end
  end

  describe "the deck (wave 18) — the default view" do
    setup do
      w = task("dk-epic", "Epic in flight", lifecycle: "in_progress", assignee: "studio:kalle")
      task("dk-child", "Epic child", lifecycle: "open", parent_id: "dk-epic")
      task("dk-ready", "Ready standalone", lifecycle: "open", priority: 1)
      b = task("dk-blocked", "Stuck on the epic", lifecycle: "blocked")
      o = task("dk-backlog", "Backlog behind the epic", lifecycle: "open")
      Repo.insert!(%Edge{from_id: b.id, to_id: w.id, kind: "blocks"})
      Repo.insert!(%Edge{from_id: o.id, to_id: w.id, kind: "blocks"})
      task("dk-done-1", "Shipped one", lifecycle: "done")
      task("dk-done-2", "Shipped two", lifecycle: "done")
      :ok
    end

    test "one phone rail, relevance-ordered, Done as the last card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ ~s(data-role="deck")
      refute html =~ ~s(data-role="column")

      # relevance order: in flight → ready → blocked → open backlog…
      [_, deck] = String.split(html, ~s(data-role="deck"), parts: 2)
      at = fn id -> deck |> :binary.match(~s(data-doc-id="#{id}")) |> elem(0) end
      assert at.("dk-epic") < at.("dk-ready")
      assert at.("dk-ready") < at.("dk-blocked")
      assert at.("dk-blocked") < at.("dk-backlog")

      # …and the ledger phone closes the rail with the full done count.
      assert html =~ ~s(data-role="deck-done")
      [_, ledger] = String.split(html, ~s(data-role="deck-done"), parts: 2)
      assert ledger =~ "Shipped one"
      assert done_count(html) == 2

      # the family still rides the epic's card; status is a chip, not a column.
      assert html =~ ~s(data-role="family-row")
      assert html =~ ~s(data-role="deck-state")
      assert html =~ "in flight"
    end

    test "deck cards expand into the gantt on click and are never drag surfaces",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/projects")

      # scope to the deck markup (the page's inline hook JS mentions the
      # draggable attribute as source text, and it trails </main>).
      [_, deck] = String.split(html, ~s(data-role="deck"), parts: 2)
      deck = deck |> String.split("</main>", parts: 2) |> hd()
      refute deck =~ ~s(draggable="true")
      refute deck =~ ~s(phx-hook="BarkparkBoardDrag")

      # wave 23: the in-flight epic greets you EXPANDED — gantt on load, the
      # list is the chart (root row first, family beneath).
      assert html =~ ~s(data-role="gantt")
      assert html =~ ~s(data-role="gantt-bar")
      [_, gantt] = String.split(html, ~s(data-role="gantt"), parts: 2)
      assert gantt =~ ~s(data-doc-id="dk-epic")
      assert gantt =~ ~s(data-doc-id="dk-child")

      # clicking a NON-expanded card narrows the expansion to it…
      view
      |> element(~s{[data-role="task-card"][data-doc-id="dk-ready"]})
      |> render_click()

      assert_patch(view, "/admin/projects?expand=dk-ready")
      narrowed = render(view)
      # …the explicit selection collapses the auto-expanded epic.
      assert occurrences(narrowed, ~s(data-role="gantt")) == 1

      # a gantt row click peeks that task with the timeline still open.
      view
      |> element(~s{[data-role="gantt-row"][data-doc-id="dk-ready"] button})
      |> render_click()

      assert_patch(view, "/admin/projects?expand=dk-ready&task=dk-ready")
      assert render(view) =~ ~s(data-role="peek")

      # × collapses to the QUIET deck — the explicit none sentinel (peek stays).
      view |> element(~s{[data-role="expand-close"]}) |> render_click()
      assert_patch(view, "/admin/projects?expand=none&task=dk-ready")
      refute render(view) =~ ~s(data-role="gantt-bar")
    end

    test "in-flight cards auto-expand by default; criteria ride the chart as segments (wave 23)",
         %{conn: conn} do
      task("dk-crit", "Claimed with checks",
        lifecycle: "in_progress",
        assignee: "studio:kalle",
        criteria: [
          %{"criterion" => "first check met", "met" => true},
          %{"criterion" => "second check open", "met" => false}
        ]
      )

      {:ok, _view, html} = live(conn, "/admin/projects")

      # both in-flight cards are open; the ready card is not.
      [_, deck] = String.split(html, ~s(data-role="deck"), parts: 2)
      deck = deck |> String.split("</main>", parts: 2) |> hd()
      assert occurrences(deck, "is-expanded") >= 2
      # criteria render as HORIZONTAL CHECK CHIPS on the claimed card's chart:
      assert deck =~ ~s(data-role="gantt-criterion")
      assert deck =~ "first check met"
      # the met chip lights, the next unmet chip pulses.
      assert deck =~ "bp-check is-met"
      assert deck =~ "bp-check is-next"
    end
  end

  describe "readable cards (wave 19)" do
    setup do
      task("rd-epic", "Epic with a brief",
        lifecycle: "in_progress",
        assignee: "lead",
        description: "The epic exists to retire the divide formulas.\nSecond line of the brief.",
        design_doc: "pd-layout-engine-paper"
      )

      task("rd-wip", "Child in flight",
        lifecycle: "in_progress",
        parent_id: "rd-epic",
        assignee: "studio:doey",
        description: "Porting the columns renderer to the two-pass solver.",
        criteria: [
          %{"criterion" => "solver flag flipped for columns", "met" => true},
          %{"criterion" => "golden-diff green at 3 widths", "met" => false}
        ]
      )

      task("rd-open", "Quiet child",
        lifecycle: "open",
        parent_id: "rd-epic",
        description: "NEVER-ON-THE-ROW: only in-flight rows carry text.",
        criteria: [%{"criterion" => "QUIET-CRITERION never on the row", "met" => false}]
      )

      task("rd-bare", "Bare epic", lifecycle: "in_progress")
      task("rd-bare-c", "Bare child", lifecycle: "open", parent_id: "rd-bare")
      :ok
    end

    test "the phone reads: root brief, ongoing task's text, paper chip, missing-brief hint",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      # the root's own brief renders on the card…
      assert html =~ ~s(data-role="card-desc")
      assert html =~ "retire the divide formulas"
      # …the ONGOING child's text rides its family row…
      assert html =~ ~s(data-role="family-desc")
      assert html =~ "Porting the columns renderer"
      # …but a non-in-flight child's text never does.
      refute html =~ "NEVER-ON-THE-ROW"
      # the PortableDoc-powered detail: the design-paper chip links the reader.
      assert html =~ ~s(data-role="design-doc")
      assert html =~ ~s(href="/papers/pd-layout-engine-paper")
      # a family card with NO brief at all says so.
      assert html =~ ~s(data-role="brief-missing")
    end

    test "the whole family renders — a ten-child epic shows all ten rows",
         %{conn: conn} do
      for i <- 1..10,
          do: task("rd-many-#{i}", "Wide child #{i}", lifecycle: "open", parent_id: "rd-epic")

      {:ok, _view, html} = live(conn, "/admin/projects")

      for i <- 1..10, do: assert(html =~ "Wide child #{i}")
      refute html =~ ~s(data-role="family-more")
    end

    test "the ongoing task's criteria checklist rides its row (wave 20)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      # the in-flight child's checklist renders under its row — met AND unmet…
      assert html =~ ~s(data-role="family-criteria")
      assert html =~ "solver flag flipped for columns"
      assert html =~ "golden-diff green at 3 widths"
      # …a quiet child's criteria never do.
      refute html =~ "QUIET-CRITERION"
    end

    test "the gantt keeps the readability: active rows show brief + criteria (wave 22)",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?expand=rd-epic")

      # the expanded chart carries the in-flight child's detail under its bar…
      [_, gantt] = String.split(html, ~s(data-role="gantt"), parts: 2)
      gantt = gantt |> String.split("</main>", parts: 2) |> hd()
      assert gantt =~ ~s(data-role="gantt-detail")
      assert gantt =~ "Porting the columns renderer"
      assert gantt =~ "solver flag flipped for columns"
      assert gantt =~ "golden-diff green at 3 widths"
      # …quiet rows stay bare in the chart too.
      refute gantt =~ "NEVER-ON-THE-ROW"
      refute gantt =~ "QUIET-CRITERION"
    end

    test "the peek links the full design paper", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=rd-epic")

      assert html =~ ~s(data-role="peek-design-doc")
      assert html =~ ~s(href="/papers/pd-layout-engine-paper")
      assert html =~ "Read the full design paper"
    end
  end

  describe "inline peek (wave 24) — the detail opens below the pressed row" do
    setup do
      task("il-epic", "Inline epic", lifecycle: "in_progress", assignee: "lead")

      task("il-child", "Inline child",
        lifecycle: "in_progress",
        parent_id: "il-epic",
        assignee: "w2"
      )

      task("il-quiet", "Quiet root", lifecycle: "open")
      b = task("il-done", "Inline shipped", lifecycle: "done")
      _ = b
      :ok
    end

    test "a gantt row's detail expands beneath it — no side panel, no scrim", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/projects")

      view
      |> element(~s{[data-role="gantt-row"][data-doc-id="il-child"] [data-role="gantt-label"]})
      |> render_click()

      html = render(view)
      # hosted inline within the pressed row's gantt…
      assert html =~ ~s(data-role="peek-host")
      [_, row] = String.split(html, ~s(data-role="gantt-row" data-doc-id="il-child"), parts: 2)
      row_scope = row |> String.split(~s(data-role="gantt-row"), parts: 2) |> hd()
      assert row_scope =~ ~s(data-role="peek-host")
      assert row_scope =~ ~s(data-role="peek-state")
      assert row_scope =~ "bp task show il-child"
      # …never the aside/scrim.
      refute html =~ ~s(data-role="peek-scrim")
      refute html =~ "<aside"
    end

    test "a done-ledger row hosts its detail inline too", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?task=il-done")

      [_, ledger] = String.split(html, ~s(data-role="done-ledger"), parts: 2)
      assert ledger =~ ~s(data-role="peek-host")
      refute html =~ ~s(data-role="peek-scrim")
    end

    test "a peeked task with no visible row falls back to the side panel", %{conn: conn} do
      # il-quiet is an open, non-expanded root — no gantt row hosts it.
      {:ok, _view, html} = live(conn, "/admin/projects?task=il-quiet")

      assert html =~ ~s(data-role="peek-scrim")
      assert html =~ "<aside"
      assert html =~ "Quiet root"
    end
  end

  describe "settled lanes (wave 11) — grouped" do
    setup do
      task("sl-live", "Live under goal-live", lifecycle: "open", parent_id: "goal-live")
      task("sl-done", "Done under goal-live", lifecycle: "done", parent_id: "goal-live")
      task("sd-one", "Shipped one", lifecycle: "done", parent_id: "goal-done")
      task("sd-two", "Shipped two", lifecycle: "done", parent_id: "goal-done")
      :ok
    end

    test "a fully-done lane collapses to a receipt; live lanes keep their board",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects?group=goal")

      # the settled lane is a receipt with tally + ledger, not a column grid…
      assert html =~ ~s(data-role="lane-settled")
      assert html =~ "all 2 done"
      assert html =~ ~s(data-role="done-ledger")
      assert html =~ "Shipped one"
      # …so the ONLY columns on the page are the live lane's five.
      assert occurrences(html, ~s(data-role="column")) == 5
    end

    test "the flat board with live work renders the deck, never the settled state",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      refute html =~ ~s(data-role="board-settled")
      assert html =~ ~s(data-role="deck")
      refute html =~ ~s(data-role="column")
    end
  end

  describe "settled board (wave 11) — flat, everything done" do
    setup do
      task("fd-one", "First shipped", lifecycle: "done")
      task("fd-two", "Second shipped", lifecycle: "done")
      task("fc-one", "Dropped idea", lifecycle: "cancelled")
      :ok
    end

    test "swaps the column skeleton for the pipeline-clear state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/projects")

      assert html =~ ~s(data-role="board-settled")
      assert html =~ "Pipeline clear"
      assert html =~ "2 tasks done"
      # no columns, no empty-board state — the settled state owns the canvas…
      refute html =~ ~s(data-role="column")
      refute html =~ ~s(data-role="board-empty")
      # …while the momentum header and the done ledger stay.
      assert html =~ ~s(data-role="momentum")
      assert html =~ ~s(data-role="done-ledger")
      assert html =~ "First shipped"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp occurrences(html, needle), do: html |> String.split(needle) |> length() |> Kernel.-(1)

  # A task persisted with an explicit workspace_id (D12): the fenced restage
  # writes resolve the Default-workspace scope, so a claimable/closable row must
  # carry that workspace_id to be found by the fresh-read + primitive.
  defp scoped_task(doc_id, title, workspace_id, opts) do
    content =
      %{"lifecycle_status" => Keyword.fetch!(opts, :lifecycle)}
      |> put_some("priority", opts[:priority])
      # PDS-D291: a drag carries no close reason, so a card that must survive a
      # drop on Done needs acceptance criteria — `task/3` above already takes
      # `:criteria`, and this twin silently DROPPED it, which reads as "the
      # option had no effect" rather than as a missing key.
      |> put_some("acceptance_criteria", opts[:criteria])
      |> put_some("claim", opts[:claim])

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "task",
      dataset: "production",
      status: "published",
      title: title,
      rev: "rev-#{doc_id}",
      workspace_id: workspace_id,
      content: content
    })
  end

  # A broadcast `doc` map (atom keys) exactly as `Content.Broadcast` shapes it:
  # `%{doc_id, title, status, content, updated_at}`.
  defp msg_doc(doc_id, title, opts) do
    %{
      doc_id: doc_id,
      title: title,
      status: Keyword.get(opts, :status, "published"),
      content: Keyword.get(opts, :content, %{}),
      updated_at: Keyword.get(opts, :updated_at, ~U[2026-07-07 12:00:00Z])
    }
  end

  # A full `{:document_changed, msg}` tuple as it arrives on the PubSub topic.
  defp task_event(doc_id, title, mutation, content, updated_at) do
    {:document_changed,
     %{
       type: "task",
       mutation: mutation,
       doc: msg_doc(doc_id, title, content: content, updated_at: updated_at)
     }}
  end

  defp claimed_event(doc_id, title) do
    task_event(
      doc_id,
      title,
      "task.claimed",
      %{"lifecycle_status" => "in_progress"},
      ~U[2026-07-07 13:00:00Z]
    )
  end

  defp closed_event(doc_id, title) do
    task_event(
      doc_id,
      title,
      "task.closed",
      %{"lifecycle_status" => "done"},
      ~U[2026-07-07 13:05:00Z]
    )
  end

  # The integer the Done column header prints in its `col-count` span.
  defp done_count(html) do
    # the deck's ledger card (flat view) or the done column (grouped view) —
    # whichever comes first carries the count pill.
    anchor =
      if String.contains?(html, ~s(data-role="deck-done")),
        do: ~s(data-role="deck-done"),
        else: ~s(data-col="done")

    [_before, rest] = String.split(html, anchor, parts: 2)
    [_h, tail] = String.split(rest, ~s(data-role="col-count">), parts: 2)
    tail |> String.trim_leading() |> Integer.parse() |> elem(0)
  end

  # Does the rendered board place `doc_id`'s card inside `col`'s <section>? We
  # slice the HTML at the target column's marker and check the card lands before
  # the next column boundary.
  defp card_in_column?(html, doc_id, col) do
    case String.split(html, ~s(data-role="column" data-col="#{col}")) do
      [_before, rest] ->
        segment = rest |> String.split(~s(data-role="column")) |> hd()
        String.contains?(segment, ~s(data-doc-id="#{doc_id}"))

      _ ->
        false
    end
  end

  # Count Repo queries that touch the `task_edges` table within `fun` — the unique
  # signature of `Board.snapshot/1`'s `load_blocker_targets`. No pid filter: the
  # connected mount runs in a spawned LiveView process, so the counter must see
  # queries from ANY process during the block (safe — this module is async:
  # false, so nothing else runs concurrently).
  defp count_edge_queries(fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      @repo_query_event,
      fn _event, _measurements, %{source: source}, _config ->
        if source == "task_edges", do: Agent.update(counter, &(&1 + 1))
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end

  defp task(doc_id, title, opts) do
    content =
      %{"lifecycle_status" => Keyword.fetch!(opts, :lifecycle)}
      |> put_some("priority", opts[:priority])
      |> put_some("parent_id", opts[:parent_id])
      |> put_some("labels", opts[:labels])
      |> put_some("assignee", opts[:assignee])
      |> put_some("acceptance_criteria", opts[:criteria])
      |> put_some("github", opts[:github])
      |> put_some("description", opts[:description])
      |> put_some("purpose", opts[:purpose])
      |> put_some("design_doc", opts[:design_doc])
      |> put_some("claim", opts[:claim])

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "task",
      dataset: "production",
      status: "published",
      title: title,
      rev: opts[:rev] || "rev-#{doc_id}",
      content: content
    })
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # The permissive visibility predicate the pure `card_from_broadcast/3` /
  # `apply_change/3` unit tests inject: no schema means every field reads
  # (legacy parity). The gating behavior gets its own redaction cases.
  defp all_readable, do: fn _ -> true end

  defp card(status, opts \\ []) do
    %{
      doc_id: Keyword.get(opts, :doc_id, "c-#{status}-#{System.unique_integer([:positive])}"),
      title: Keyword.get(opts, :title, status),
      priority: Keyword.get(opts, :priority),
      parent_id: Keyword.get(opts, :parent_id),
      labels: Keyword.get(opts, :labels, []),
      worker: Keyword.get(opts, :worker),
      lifecycle_status: status,
      criteria: Keyword.get(opts, :criteria),
      github: Keyword.get(opts, :github),
      github_synced: Keyword.get(opts, :github_synced, false),
      blocker_statuses: Keyword.get(opts, :blocker_statuses, []),
      updated_at: Keyword.get(opts, :updated_at, DateTime.utc_now())
    }
  end
end
