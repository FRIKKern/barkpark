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

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Board
  alias Barkpark.Tasks.Edge

  @admin_token "projects-board-admin-test-token"

  setup do
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

      assert %Barkpark.Structure.Node{title: "Projects"} = node,
             "the /admin/projects link must appear in the desk"
    end
  end

  describe "Board.build/2 (pure organizer)" do
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

  describe "Board.card_from_broadcast/2 (pure, wave 2)" do
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

      c = Board.card_from_broadcast(doc, prev)

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

      c = Board.card_from_broadcast(doc, nil)

      assert c.worker == "cmux-7"
      # unseen (prev == nil) → empty blockers; readiness waits for :refresh.
      assert c.blocker_statuses == []
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
          prev
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
          prev
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
          prev
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
      assert card_in_column?(html, "rt-open", "in_progress")
    end

    test "a task.closed event climbs done-today and flashes the closed card", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin/projects")
      assert html =~ "0 done today"

      send(view.pid, closed_event("rt-wip", "Already working"))
      html = render(view)

      assert html =~ "1 done today"
      assert html =~ ~s(data-just-moved)
      assert card_in_column?(html, "rt-wip", "done")
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

      # exactly 12 done cards render (the window), but the Done column count is 13.
      done_cards =
        html
        |> String.split(~s(data-role="column" data-col="done"))
        |> List.last()
        |> String.split(~s(data-role="task-card"))
        |> length()
        |> Kernel.-(1)

      assert done_cards == 12, "the done render is windowed at 12; got #{done_cards}"
      assert done_count(html) == 13, "the Done column count must report the full total"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

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
    [_before, rest] = String.split(html, ~s(data-col="done"), parts: 2)
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

  defp task(doc_id, title, opts) do
    content =
      %{"lifecycle_status" => Keyword.fetch!(opts, :lifecycle)}
      |> put_some("priority", opts[:priority])
      |> put_some("parent_id", opts[:parent_id])
      |> put_some("labels", opts[:labels])
      |> put_some("assignee", opts[:assignee])
      |> put_some("acceptance_criteria", opts[:criteria])
      |> put_some("github", opts[:github])

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
