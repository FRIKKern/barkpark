defmodule BarkparkWeb.Studio.StudioAriaStateValuesTest do
  @moduledoc """
  The editor's toggle and tabs tell assistive technology which one is on
  (task-8e841919259c85fb).

  HEEx renders a boolean `true` as a bare attribute: `aria-pressed={x == y}`
  became `aria-pressed=""` (and `false` dropped it), which ARIA reads as
  undefined, so neither the pressed Classic/Beta mode nor the selected view or
  field-group tab was announced. The values must be the strings "true"/"false".
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "series",
          "title" => "Serie",
          "visibility" => "public",
          "groups" => [
            %{"name" => "main", "title" => "Main"},
            %{"name" => "meta", "title" => "Meta"}
          ],
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string", "group" => "main"},
            %{"name" => "note", "title" => "Notat", "type" => "string", "group" => "meta"}
          ],
          "layout" => [
            %{"kind" => "field", "name" => "title"},
            %{"kind" => "field", "name" => "note"},
            %{"kind" => "region", "name" => "body"}
          ],
          "desk" => %{
            "views" => [
              %{
                "id" => "books",
                "title" => "Bøker i serien",
                "type" => "series",
                "by" => "content.parent"
              }
            ]
          }
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "series",
        %{"doc_id" => "aria-series", "title" => "Serien", "content" => %{"title" => "Serien"}},
        @dataset
      )

    :ok
  end

  defp attr(html, selector, name) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  test "the Classic/Beta toggle and the view and group tabs carry string states",
       %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/series/aria-series"))

    assert attr(html, ~s([data-test-id="editor-mode-classic"]), "aria-pressed") == ["true"]
    assert attr(html, ~s([data-test-id="editor-mode-beta"]), "aria-pressed") == ["false"]

    assert attr(html, ~s([data-test-id="document-view-form"]), "aria-selected") == ["true"]
    assert attr(html, ~s([data-test-id="document-view-tab"]), "aria-selected") == ["false"]

    assert attr(html, ~s(.bp-tab-bar [role="tab"]), "aria-selected") == ["true", "false"]

    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()
    assert attr(html, ~s([data-test-id="editor-mode-classic"]), "aria-pressed") == ["false"]
    assert attr(html, ~s([data-test-id="editor-mode-beta"]), "aria-pressed") == ["true"]
  end
end
