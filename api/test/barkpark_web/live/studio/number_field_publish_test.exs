defmodule BarkparkWeb.Studio.NumberFieldPublishTest do
  @moduledoc """
  task-63c17c67c6644377 — a `number` field must hold a number before Studio
  publishes it.

  Found dogfooding: type "abc" into a schema's number field (Count) and press
  Publish — Studio said "Published" and the API served {"count": "abc"}. The
  Classic numeric input is a text input, and the save keeps an unparseable
  value as the typed string.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "notice",
          "title" => "Notice",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "count", "title" => "Count", "type" => "number"}
          ]
        },
        @dataset
      )

    {:ok, _} = Content.create_document("notice", %{"doc_id" => "n1", "title" => "N"}, @dataset)
    :ok
  end

  test "a non-numeric value in a number field blocks publish, inline on the field", %{conn: conn} do
    {:ok, view, _} = live(conn, scoped_studio("/d/#{@dataset}/studio/notice/n1"))
    render_change(view, "autosave", %{"doc" => %{"title" => "N", "count" => "abc"}})

    html = render_click(view, "publish")

    assert html =~ "Fix validation errors before publishing"
    assert html =~ "Must be a number"
    assert {:error, _} = Content.get_document("n1", "notice", @dataset)
  end

  test "a numeric value publishes as a number", %{conn: conn} do
    {:ok, view, _} = live(conn, scoped_studio("/d/#{@dataset}/studio/notice/n1"))
    render_change(view, "autosave", %{"doc" => %{"title" => "N", "count" => "7.5"}})

    html = render_click(view, "publish")

    refute html =~ "Must be a number"
    assert {:ok, published} = Content.get_document("n1", "notice", @dataset)
    assert published.content["count"] == 7.5
  end
end
