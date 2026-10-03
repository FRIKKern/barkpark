defmodule BarkparkWeb.Studio.ClassicLabelsNameInputsTest do
  @moduledoc """
  Every Classic field label must name its control, so a screen reader
  announces "Title, edit text" rather than an unnamed text field. Found
  dogfooding: on a post, none of title, slug, status, published-at or
  excerpt had an associated label (`input.labels.length == 0` in Chrome),
  and Playwright's `getByLabel("Title")` found nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"},
            %{
              "name" => "status",
              "title" => "Status",
              "type" => "select",
              "options" => ["a", "b"]
            },
            %{"name" => "when", "title" => "When", "type" => "datetime"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "text"},
            %{"name" => "pinned", "title" => "Pinned", "type" => "boolean"},
            %{"name" => "body", "title" => "Body", "type" => "richText"}
          ]
        },
        @dataset
      )

    {:ok, _} = Content.create_document("note", %{"doc_id" => "n1", "title" => "One"}, @dataset)
    :ok
  end

  test "each scalar field's label points at an element with that id", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/note/n1"))

    for {label, name} <- [
          {"Title", "title"},
          {"Slug", "slug"},
          {"Status", "status"},
          {"When", "when"},
          {"Excerpt", "excerpt"},
          {"Pinned", "pinned"}
        ] do
      [_, for_id] =
        Regex.run(~r{<label class="editor-field-label" for="([^"]+)">\s*#{label}\b}, html) ||
          flunk("the #{label} label carries no for= attribute")

      assert html =~
               ~r{<(?:input|select|textarea)[^>]*id="#{Regex.escape(for_id)}"[^>]*name="doc\[#{name}\]"},
             "the #{label} label points at #{for_id}, which is not the doc[#{name}] control"
    end
  end

  test "a web-component field's label points at nothing rather than at a missing id", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/note/n1"))
    assert html =~ ~r{<label class="editor-field-label">\s*Body\b}
  end
end
