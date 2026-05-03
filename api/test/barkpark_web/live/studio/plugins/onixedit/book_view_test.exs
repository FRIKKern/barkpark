defmodule BarkparkWeb.Studio.Plugins.OnixEdit.BookViewTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"
  @doc_id "wi3-book-view-1"
  @drafts_doc_id "wi3-book-view-drafts-1"

  setup %{conn: conn} do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book (ONIX 3.0)",
          "icon" => "book",
          "visibility" => "private",
          "fields" => [
            %{"name" => "isbn", "title" => "ISBN", "type" => "string"},
            %{
              "name" => "titleDetail",
              "title" => "Title detail",
              "type" => "composite",
              "fields" => [
                %{"name" => "main", "type" => "string"}
              ]
            },
            %{
              "name" => "contributors",
              "title" => "Contributors",
              "type" => "arrayOf",
              "ordered" => true,
              "of" => %{"name" => "person", "type" => "string"}
            },
            %{
              "name" => "productForm",
              "title" => "Product form",
              "type" => "codelist",
              "codelistId" => "onix:list150",
              "version" => 73
            },
            %{
              "name" => "blurb",
              "title" => "Blurb",
              "type" => "localizedText",
              "languages" => ["eng", "nor"],
              "format" => "plain",
              "fallbackChain" => ["eng"]
            }
          ]
        },
        @dataset
      )

    {:ok, _doc} =
      Content.create_document(
        "book",
        %{
          "doc_id" => @doc_id,
          "title" => "WI3 Test Book",
          "content" => %{
            "isbn" => "9781234567897",
            "titleDetail" => %{"main" => "WI3 Test Book"},
            "contributors" => ["Author A", "Author B"],
            "productForm" => "BB",
            "blurb" => %{"eng" => "English blurb", "nor" => "Norsk blurb"}
          }
        },
        @dataset
      )

    {:ok, _draft} =
      Content.create_document(
        "book",
        %{
          "doc_id" => "drafts." <> @drafts_doc_id,
          "title" => "WI3 Draft Book",
          "content" => %{"isbn" => "9789999999996"}
        },
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "BookView detail render" do
    test "renders header, _id, timestamps, and an editor link without /view", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}/view")

      assert html =~ "WI3 Test Book"
      assert html =~ @doc_id
      assert html =~ "_createdAt"
      assert html =~ "_updatedAt"

      editor_href = "/studio/#{@dataset}/onixedit/book/#{@doc_id}"
      assert html =~ ~s|href="#{editor_href}"|
      refute html =~ ~s|href="#{editor_href}/view"|
      assert html =~ "Open in editor"
    end

    test "v1 string field renders raw value", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}/view")
      assert html =~ "9781234567897"
    end

    test "v2 composite/arrayOf/localizedText render inside <details><pre>", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}/view")

      assert html =~ "<details"
      assert html =~ "<pre"
      assert html =~ "Title detail"
      assert html =~ "Contributors"
      assert html =~ "2 items"
      assert html =~ "Author A"
    end

    test "codelist field renders the code value", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@doc_id}/view")
      assert html =~ "Product form"
      assert html =~ "BB"
    end
  end

  describe "drafts.* URL" do
    test "renders draft via drafts.<id> path with draft badge", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/#{@drafts_doc_id}/view")

      assert html =~ "draft"
      assert html =~ "WI3 Draft Book"
      assert html =~ "9789999999996"
    end

    test "renders the same when URL contains the literal drafts. prefix", %{conn: conn} do
      {:ok, _view, html} =
        live(conn, "/studio/#{@dataset}/onixedit/book/drafts.#{@drafts_doc_id}/view")

      assert html =~ "WI3 Draft Book"
      assert html =~ "9789999999996"
    end
  end

  describe "missing document" do
    test "renders empty state without crashing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/onixedit/book/does-not-exist-xyz/view")

      assert html =~ "not found"
    end
  end

  describe "WI1 + redirect regression" do
    test "clicking through StudioLive to a book doc redirects to /view URL", %{conn: conn} do
      result = live(conn, "/studio/#{@dataset}/book/#{@doc_id}")

      case result do
        {:error, {:live_redirect, %{to: to}}} ->
          assert to == "/studio/#{@dataset}/onixedit/book/#{@doc_id}/view"

        {:error, {:redirect, %{to: to}}} ->
          assert to == "/studio/#{@dataset}/onixedit/book/#{@doc_id}/view"

        {:ok, _view, _html} ->
          flunk("expected a redirect to BookView, but StudioLive mounted inline")
      end
    end
  end
end
