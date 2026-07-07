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

  # ── helpers ─────────────────────────────────────────────────────────────────

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
