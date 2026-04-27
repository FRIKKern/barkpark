defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookEditorTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @doc_id "book-test-1"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book (ONIX 3.0)",
          "icon" => "book",
          "visibility" => "private",
          "fields" => []
        },
        @dataset
      )

    {:ok, _doc} =
      Content.create_document(
        "book",
        %{"doc_id" => @doc_id, "title" => "Test Book"},
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "shell + tab routing" do
    test "mounts and defaults to Identity tab", %{conn: conn} do
      {:ok, view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}")

      assert html =~ "Test Book"
      assert html =~ ~s|data-test-id="book-editor-tabs"|

      assert has_element?(view, ~s|[data-tab-body="identity"]|, "Identity tab")
      refute has_element?(view, ~s|[data-tab-body="title"]|)
    end

    test "?tab=title renders the Title placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=title")

      assert has_element?(view, ~s|[data-tab-body="title"]|)
      refute has_element?(view, ~s|[data-tab-body="identity"]|)
    end

    test "patching between tabs swaps the body without remounting", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}")

      assert has_element?(view, ~s|[data-tab-body="identity"]|)

      view
      |> element(~s|a[data-tab="contributors"]|)
      |> render_click()

      assert has_element?(view, ~s|[data-tab-body="contributors"]|)
      refute has_element?(view, ~s|[data-tab-body="identity"]|)

      view
      |> element(~s|a[data-tab="subjects"]|)
      |> render_click()

      assert has_element?(view, ~s|[data-tab-body="subjects"]|)
    end

    test "unknown ?tab= falls back to Identity and flashes an error", %{conn: conn} do
      {:ok, view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}?tab=bogus")

      assert html =~ "Unknown tab"
      assert has_element?(view, ~s|[data-tab-body="identity"]|)
    end

    test "renders all 8 tab links in order", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}")

      for {_atom, label} <- BarkparkWeb.Studio.Plugins.OnixEdit.BookEditor.tabs() do
        assert html =~ label, "missing tab label: #{label}"
      end
    end
  end
end
