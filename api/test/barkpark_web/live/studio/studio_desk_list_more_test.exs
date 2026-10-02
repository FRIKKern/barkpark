defmodule BarkparkWeb.Studio.DeskListMoreTest do
  @moduledoc """
  A desk list pane used to stop at the 100-row page `Content.list_documents/3`
  reads, with a header count of exactly 100 and no way to reach the 101st
  document (stranger walk, 2026-10-01: 131 widgets showed "Widget 100"). The
  pane now reads `list_documents_page/3`, marks the count as a floor ("100+")
  and offers "Show more", which loads the next page.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup %{conn: conn} do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "gadget",
          "title" => "Gadget",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "widgetlet",
          "title" => "Widgetlet",
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for i <- 1..105 do
      {:ok, _} =
        Content.create_document(
          "gadget",
          %{"doc_id" => "gadget-#{i}", "title" => "Gadget #{i}"},
          @dataset
        )
    end

    for i <- 1..3 do
      {:ok, _} =
        Content.create_document(
          "widgetlet",
          %{"doc_id" => "widgetlet-#{i}", "title" => "Widgetlet #{i}"},
          @dataset
        )
    end

    {:ok, conn: conn}
  end

  defp rows(html, type), do: length(Regex.scan(~r/id="doc-#{type}-\d+"/, html))

  test "a truncated list says so and Show more loads the rest", %{conn: conn} do
    {:ok, view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/content-types/gadget"))

    assert rows(html, "gadget") == 100
    assert html =~ ~r/class="pane-header-count">100\+</
    assert html =~ ~s(data-test-id="desk-list-more")

    html = view |> element(~s([data-test-id="desk-list-more"])) |> render_click()

    assert rows(html, "gadget") == 105
    refute html =~ ~s(data-test-id="desk-list-more")
    assert html =~ ~r/class="pane-header-count">105</
  end

  test "a list that fits shows neither the + nor Show more", %{conn: conn} do
    {:ok, _view, html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/content-types/widgetlet"))

    assert rows(html, "widgetlet") == 3
    assert html =~ ~r/class="pane-header-count">3</
    refute html =~ ~s(data-test-id="desk-list-more")
  end
end
