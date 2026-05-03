defmodule BarkparkWeb.Studio.ApiTesterLiveSchemaBrowserTest do
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _post} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Posts",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"}
          ]
        },
        @dataset
      )

    {:ok, _book} =
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
            }
          ]
        },
        @dataset
      )

    {:ok, conn: conn}
  end

  describe "Schema reference panel" do
    test "registers a 'Schema reference' card in the endpoint list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/api-tester")
      assert html =~ "Schema reference"
      assert html =~ "ref-schemas"
    end

    test "selecting it renders the book schema with its fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/api-tester")

      html = render_click(view, "select", %{"id" => "ref-schemas"})

      assert html =~ "book"
      assert html =~ "Book (ONIX 3.0)"
      assert html =~ "Private schemas"
      assert html =~ "isbn"
      assert html =~ "titleDetail"
      assert html =~ "<details"
    end

    test "v2 composite field renders inside <details><pre> JSON", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/api-tester")
      html = render_click(view, "select", %{"id" => "ref-schemas"})

      assert html =~ "<pre"
      assert html =~ "titleDetail"
      assert html =~ "composite"
    end

    test "regression — legacy public schema (post) also appears", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/#{@dataset}/api-tester")
      html = render_click(view, "select", %{"id" => "ref-schemas"})

      assert html =~ "Public schemas"
      assert html =~ "post"
      assert html =~ "Posts"
    end

    test "regression — existing endpoint cards still render", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/#{@dataset}/api-tester")

      assert html =~ "List documents"
      assert html =~ "Document envelope"
      assert html =~ "Error codes"
    end
  end
end
