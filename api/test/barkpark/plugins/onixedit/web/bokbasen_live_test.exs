defmodule Barkpark.Plugins.OnixEdit.Web.BokbasenLiveTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.QueryCounter
  use Oban.Testing, repo: Barkpark.Repo

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Repo

  @admin_token "bokbasen-admin-test-token"
  @junior_token "bokbasen-junior-test-token"

  @url "/admin/onixedit/bokbasen"

  # Default Ecto telemetry event for a repo with `otp_app: :barkpark`.
  # Mirrors @page_limit in BokbasenLive — the LIMIT that caps `load_submissions`
  # so `all_submissions` cannot grow with the total book-document count. Keep in
  # sync with the source constant.
  @page_limit 200

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])

    {:ok, conn: conn}
  end

  defp seed_book(doc_id, bp_status_map) do
    content =
      case bp_status_map do
        nil -> %{}
        m -> %{"bp_export_status" => Jason.encode!(m)}
      end

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Book " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev_" <> doc_id
      })
      |> Repo.insert()

    doc
  end

  describe "admin gate" do
    test "redirects to /studio without an admin token", %{conn: conn} do
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, @url)
    end

    test "redirects to /studio for non-admin tokens", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, @url)
    end
  end

  describe "empty state" do
    test "shows the friendly empty-state message when no submissions exist", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, @url)

      assert html =~ "Bokbasen Submissions"
      assert has_element?(view, ~s|[data-test-id="bokbasen-empty"]|)
    end
  end

  describe "table" do
    test "renders one row per submission with the right pill class", %{conn: conn} do
      seed_book("row-accept", %{
        "state" => "accepted",
        "bokbasen_submission_id" => "s1",
        "updated_at" => "2026-04-30T10:00:00.000000Z"
      })

      seed_book("row-failed", %{
        "state" => "failed",
        "last_error" => %{"type" => "auth", "summary" => "AuthError"},
        "updated_at" => "2026-04-30T11:00:00.000000Z"
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, @url)

      assert html =~ "row-accept"
      assert html =~ "row-failed"
      assert has_element?(view, ~s|tr[data-test-doc-id="row-accept"] [data-test-pill="accepted"]|)
      assert has_element?(view, ~s|tr[data-test-doc-id="row-failed"] [data-test-pill="failed"]|)
      assert html =~ "bp-pill-green"
      assert html =~ "bp-pill-orange"
    end
  end

  describe "retry button" do
    test "enqueues PublishWorker on click for terminal-error rows", %{conn: conn} do
      seed_book("retry-me", %{
        "state" => "failed",
        "updated_at" => "2026-04-30T10:00:00.000000Z"
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      view
      |> element(~s|tr[data-test-doc-id="retry-me"] button[data-test-action="retry"]|)
      |> render_click()

      assert_enqueued(
        worker: PublishWorker,
        args: %{"document_id" => "retry-me", "type" => "book", "dataset" => "production"}
      )
    end

    test "is disabled on non-terminal rows", %{conn: conn} do
      seed_book("polling-row", %{
        "state" => "polling",
        "updated_at" => "2026-04-30T10:00:00.000000Z"
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      assert has_element?(
               view,
               ~s|tr[data-test-doc-id="polling-row"] button[data-test-action="retry-disabled"][disabled]|
             )

      refute has_element?(
               view,
               ~s|tr[data-test-doc-id="polling-row"] button[data-test-action="retry"]|
             )
    end
  end

  describe "PubSub" do
    test "broadcasts update a row's pill in real time", %{conn: conn} do
      seed_book("live-row", %{
        "state" => "polling",
        "bokbasen_submission_id" => "sub-live",
        "updated_at" => "2026-04-30T10:00:00.000000Z"
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      assert has_element?(view, ~s|tr[data-test-doc-id="live-row"] [data-test-pill="polling"]|)

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "bokbasen:document:live-row",
        {:bokbasen_status_update,
         %{
           "doc_id" => "live-row",
           "state" => "accepted",
           "bokbasen_submission_id" => "sub-live",
           "updated_at" => "2026-04-30T10:05:00.000000Z"
         }}
      )

      html = render(view)
      assert html =~ "bp-pill-green"
      assert has_element?(view, ~s|tr[data-test-doc-id="live-row"] [data-test-pill="accepted"]|)
    end
  end

  describe "filter by state" do
    test "unchecking a state hides matching rows", %{conn: conn} do
      seed_book("f-acc", %{"state" => "accepted", "updated_at" => "2026-04-30T10:00:00.000000Z"})
      seed_book("f-fail", %{"state" => "failed", "updated_at" => "2026-04-30T10:00:00.000000Z"})

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, @url)

      assert html =~ "f-acc"
      assert html =~ "f-fail"

      view
      |> element(~s|input[phx-value-state="accepted"]|)
      |> render_click()

      html2 = render(view)
      refute html2 =~ ~r/data-test-doc-id="f-acc"/
      assert html2 =~ "f-fail"
    end
  end

  describe "back-compat redirect" do
    test "GET /admin/bokbasen 301-redirects to the new plugin path", %{conn: conn} do
      conn = get(conn, "/admin/bokbasen")
      assert conn.status == 301
      assert Plug.Conn.get_resp_header(conn, "location") == ["/admin/onixedit/bokbasen"]
    end
  end

  # PROTECTIVE TEST (task-felix-bokbasen-unbounded-mount, d07 F2 scar class):
  # mount/3 used to call `load_submissions/0` UNCONDITIONALLY — projecting the
  # full `documents` table on BOTH the discarded disconnected render AND the live
  # mount (2× DB projection per console open). The load is now gated behind
  # `connected?/1`. These tests count queries against the `documents` source —
  # the unique signature of `load_submissions` (nothing else on this mount reads
  # documents) — to prove 2× → 1× and zero on the dead render.
  describe "disconnected mount elides the DB projection" do
    test "the disconnected (dead) render runs ZERO documents-projection queries and paints no rows",
         %{conn: conn} do
      seed_book("dead-render-row", %{
        "state" => "accepted",
        "updated_at" => "2026-04-30T10:00:00.000000Z"
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {conn, doc_reads} = count_document_queries(fn -> get(conn, @url) end)

      body = html_response(conn, 200)
      # The dead render carries the empty page, NOT the projected submission.
      assert body =~ ~s(data-test-id="bokbasen-empty")
      refute body =~ "dead-render-row"

      assert doc_reads == 0,
             "the disconnected mount must issue zero documents-projection queries, " <>
               "got #{doc_reads}"
    end

    test "the connected mount runs load_submissions exactly once (2x -> 1x)", %{conn: conn} do
      seed_book("live-projection-row", %{
        "state" => "accepted",
        "updated_at" => "2026-04-30T10:00:00.000000Z"
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})

      # `live/2` does the disconnected render THEN connects. The disconnected leg
      # now contributes 0 documents queries (the fix), so the ONE documents query
      # across the whole flow proves the projection runs a single time — on connect.
      {{:ok, _view, html}, doc_reads} =
        count_document_queries(fn -> live(conn, @url) end)

      # Behavior parity: the connected view shows the row as before.
      assert html =~ "live-projection-row"

      assert doc_reads == 1,
             "load_submissions must run exactly once (on connect), got #{doc_reads} documents queries"
    end
  end

  # PROTECTIVE TEST (task-felix-bokbasen-unbounded-mount): `load_submissions/0`
  # had NO limit — `all_submissions` grew with the total book-document count,
  # pinning O(total-books) into the LiveView process for the life of the socket.
  # It is now capped at @page_limit. Seed more than the cap and prove the assign
  # (and therefore the rendered table) never exceeds it.
  describe "load_submissions is bounded" do
    test "the connected mount caps all_submissions at the page limit", %{conn: conn} do
      total = @page_limit + 5

      for i <- 1..total do
        seed_book("cap-#{i}", %{
          "state" => "accepted",
          "updated_at" => "2026-04-30T10:00:00.000000Z"
        })
      end

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, @url)

      # All loaded rows pass the default (all-states, no-date) filter, so the
      # rendered row count equals the loaded count — which must be the cap.
      rendered_rows = length(Regex.scan(~r/data-test-doc-id=/, html))

      assert rendered_rows == @page_limit,
             "the bounded mount must render exactly @page_limit (#{@page_limit}) rows out of " <>
               "#{total} seeded, got #{rendered_rows}"
    end
  end

  # PROTECTIVE TEST (task-5dbbbe2efc44e48e, felix wave 5): #2869 capped
  # `load_submissions` at @page_limit (order_by updated_at desc, limit) — bounding
  # the socket heap but making every row past the cap UNREACHABLE. OFFSET-based
  # pagination (@page assign + next_page/prev_page) makes them reachable while
  # holding the per-page bound. Seed >@page_limit books with DISTINCT document
  # `updated_at` (forced post-insert — the column is not castable) so the desc
  # order is deterministic, then prove a capped-out row is invisible on page 1 and
  # surfaces on page 2. FAILS on origin/main: there is no next_page control, so the
  # render_click below raises (no matching element).
  describe "pagination beyond the page limit" do
    test "page 2 surfaces a capped-out row that is invisible on page 1", %{conn: conn} do
      total = @page_limit + 5
      base = ~U[2026-01-01 00:00:00.000000Z]

      for i <- 1..total do
        doc_id = "pg-" <> String.pad_leading(Integer.to_string(i), 3, "0")

        seed_book(doc_id, %{
          "state" => "accepted",
          "updated_at" => "2026-04-30T10:00:00.000000Z"
        })

        # Force the DOCUMENT row's updated_at (the pagination sort key) — higher i
        # is newer, so pg-001 is the oldest row and lands on page 2.
        forced = DateTime.add(base, i, :second)

        {1, _} =
          Repo.update_all(
            from(d in Document, where: d.doc_id == ^doc_id),
            set: [updated_at: forced]
          )
      end

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, @url)

      # Page 1 (0-based @page 0): the 200 newest rows. The oldest row (pg-001) is
      # capped out; the newest (pg-205) is present.
      assert html =~ ~s(data-test-doc-id="pg-205")
      refute html =~ ~s(data-test-doc-id="pg-001")
      assert has_element?(view, ~s|[data-test-id="bokbasen-pager"]|)

      # Advance to page 2.
      html2 =
        view
        |> element(~s|button[data-test-action="next-page"]|)
        |> render_click()

      # The capped-out row now surfaces; the first-page-only row is gone.
      assert html2 =~ ~s(data-test-doc-id="pg-001")
      refute html2 =~ ~s(data-test-doc-id="pg-205")
      assert html2 =~ "Page 2"

      # Paging back returns to the first page.
      html3 =
        view
        |> element(~s|button[data-test-action="prev-page"]|)
        |> render_click()

      assert html3 =~ ~s(data-test-doc-id="pg-205")
      refute html3 =~ ~s(data-test-doc-id="pg-001")
    end

    test "a page-2 row receives live PubSub updates (resubscribe on navigation)",
         %{conn: conn} do
      total = @page_limit + 3
      base = ~U[2026-01-01 00:00:00.000000Z]

      for i <- 1..total do
        doc_id = "sub-" <> String.pad_leading(Integer.to_string(i), 3, "0")

        seed_book(doc_id, %{
          "state" => "polling",
          "updated_at" => "2026-04-30T10:00:00.000000Z"
        })

        forced = DateTime.add(base, i, :second)

        {1, _} =
          Repo.update_all(
            from(d in Document, where: d.doc_id == ^doc_id),
            set: [updated_at: forced]
          )
      end

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      # sub-001 is the oldest → page 2 only.
      view
      |> element(~s|button[data-test-action="next-page"]|)
      |> render_click()

      assert has_element?(view, ~s|tr[data-test-doc-id="sub-001"] [data-test-pill="polling"]|)

      # A broadcast on the page-2 doc must land — proving the mount subscribed the
      # NEW page's topics (resubscribe), not just page 1's.
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "bokbasen:document:sub-001",
        {:bokbasen_status_update,
         %{
           "doc_id" => "sub-001",
           "state" => "accepted",
           "updated_at" => "2026-04-30T10:05:00.000000Z"
         }}
      )

      assert has_element?(view, ~s|tr[data-test-doc-id="sub-001"] [data-test-pill="accepted"]|)
    end
  end

  # Count Repo queries against `documents` within `fun` — the unique signature of
  # `load_submissions/0` on this mount.
  #
  # LINEAGE-SCOPED, via the shared `Barkpark.QueryCounter`. The connected mount
  # runs in a spawned LiveView process, so a `self()` filter would drop the very
  # leg being measured — but an unscoped handler is NODE-global and counts the
  # application's own background processes too, which `async: false` does not
  # fence (it fences sibling TEST processes, not the supervision tree). The
  # counter therefore reports from any process and decides ownership afterwards:
  # this test process, the LiveView pid named below, and their
  # `$callers`/`$ancestors` lineage. See `Barkpark.QueryCounterTest`.
  defp count_document_queries(fun) do
    QueryCounter.count_source(
      fn ->
        result = fun.()

        case result do
          {:ok, %Phoenix.LiveViewTest.View{pid: pid}, _html} -> QueryCounter.own(pid)
          _ -> :ok
        end

        result
      end,
      "documents"
    )
  end
end
