defmodule Barkpark.Plugins.OnixEdit.Web.StalenessLiveTest do
  @moduledoc """
  Phase 8 WI4 — admin LV tests for `/admin/onixedit/staleness`. Moved
  alongside the LV when the console relocated into the OnixEdit plugin
  namespace in Goal `barkpark-G3` s4. URL is preserved by the plugin
  mount.

  Covers:

    * Auth gate — unauthenticated and non-admin tokens are redirected.
    * Empty + populated table render.
    * Re-validate event sets the diff section + flash without mutating
      the document.
    * Acknowledge event flips the doc's `staleness_acknowledged` flag
      and re-renders the gray pill.
    * Pill colour mapping is inlined per the WI5 deferral note.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @admin_token "onixedit-staleness-admin-test-token"
  @junior_token "onixedit-staleness-junior-test-token"

  @url "/admin/onixedit/staleness"

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "test admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "test junior", "production", ["read"])

    {:ok, conn: conn}
  end

  defp seed_book(doc_id, content) when is_map(content) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "book",
        "dataset" => "production",
        "title" => "Book " <> doc_id,
        "status" => "draft",
        "content" => content,
        "rev" => "rev_" <> doc_id <> "_#{System.unique_integer([:positive])}"
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
    test "shows the friendly empty-state message when no books exist", %{conn: conn} do
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, @url)

      assert html =~ "OnixEdit Codelist Staleness"
      assert has_element?(view, ~s|[data-test-id="onixedit-staleness-empty"]|)
    end
  end

  describe "table render" do
    test "renders one row per book with the correct status pill", %{conn: conn} do
      seed_book("stale-row", %{
        "notificationType" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "73"
        }
      })

      seed_book("ack-row", %{
        "notificationType" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "73"
        },
        "staleness_acknowledged" => true
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, @url)

      assert html =~ "stale-row"
      assert html =~ "ack-row"

      assert has_element?(
               view,
               ~s|tr[data-test-doc-id="ack-row"] [data-test-pill="acknowledged"]|
             )

      assert html =~ "bg-gray-100"
    end

    test "shows zero codelist refs for books with no codelist content", %{conn: conn} do
      seed_book("plain-row", %{"title" => "no codelists here"})

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      assert has_element?(
               view,
               ~s|tr[data-test-doc-id="plain-row"] [data-test-codelist-count="0"]|
             )
    end
  end

  describe "re-validate button" do
    test "fires revalidate, sets the diff section, and does NOT mutate the doc",
         %{conn: conn} do
      original_content = %{
        "notificationType" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "73"
        }
      }

      seed_book("reval-1", original_content)

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      view
      |> element(~s|tr[data-test-doc-id="reval-1"] button[data-test-action="revalidate"]|)
      |> render_click()

      html = render(view)
      assert html =~ "Last re-validate diff"
      assert html =~ "reval-1"

      # Doc content is unchanged after re-validate (read-only action).
      doc = Repo.get_by!(Document, doc_id: "reval-1", type: "book", dataset: "production")
      assert doc.content == original_content
    end
  end

  describe "acknowledge button" do
    test "writes staleness_acknowledged: true to the doc and re-renders gray pill",
         %{conn: conn} do
      seed_book("ack-flip", %{
        "notificationType" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "73"
        }
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      view
      |> element(~s|tr[data-test-doc-id="ack-flip"] button[data-test-action="acknowledge"]|)
      |> render_click()

      doc = Repo.get_by!(Document, doc_id: "ack-flip", type: "book", dataset: "production")
      assert doc.content["staleness_acknowledged"] == true

      html = render(view)

      assert has_element?(
               view,
               ~s|tr[data-test-doc-id="ack-flip"] [data-test-pill="acknowledged"]|
             )

      assert html =~ "bg-gray-100"
    end

    test "is disabled once the doc has already been acknowledged", %{conn: conn} do
      seed_book("ack-disabled", %{
        "notificationType" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "73"
        },
        "staleness_acknowledged" => true
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      assert has_element?(
               view,
               ~s|tr[data-test-doc-id="ack-disabled"] button[data-test-action="acknowledge"][disabled]|
             )
    end
  end

  describe "pill colour mapping" do
    test "uses the WI4-inlined Tailwind palette (yellow stale, green current, red deprecated)",
         %{conn: conn} do
      seed_book("colour-stale", %{
        "f" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "70"
        }
      })

      seed_book("colour-current", %{
        "f" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "73"
        }
      })

      seed_book("colour-dep", %{
        "f" => %{
          "codelistId" => "onixedit:notification_type",
          "issue_version" => "70",
          "deprecated" => true
        }
      })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, @url)

      assert html =~ "bg-yellow-100"
      assert html =~ "bg-green-100"
      assert html =~ "bg-red-100"
    end
  end

  describe "current registry indicator" do
    test "displays the current registry issue at the top of the page", %{conn: conn} do
      seed_book("with-issue", %{"title" => "anything"})

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, @url)

      assert has_element?(view, ~s|[data-test-id="current-issue"]|)
    end
  end
end
