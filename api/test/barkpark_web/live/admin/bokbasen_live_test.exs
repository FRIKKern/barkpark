defmodule BarkparkWeb.Admin.BokbasenLiveTest do
  use BarkparkWeb.ConnCase, async: false
  use Oban.Testing, repo: Barkpark.Repo

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker
  alias Barkpark.Repo

  @admin_token "bokbasen-admin-test-token"
  @junior_token "bokbasen-junior-test-token"

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
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/admin/bokbasen")
    end

    test "redirects to /studio for non-admin tokens", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/admin/bokbasen")
    end
  end

  describe "empty state" do
    test "shows the friendly empty-state message when no submissions exist", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, "/admin/bokbasen")

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
      {:ok, view, html} = live(conn, "/admin/bokbasen")

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
      {:ok, view, _html} = live(conn, "/admin/bokbasen")

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
      {:ok, view, _html} = live(conn, "/admin/bokbasen")

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
      {:ok, view, _html} = live(conn, "/admin/bokbasen")

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
      {:ok, view, html} = live(conn, "/admin/bokbasen")

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
end
