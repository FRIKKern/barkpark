defmodule BarkparkWeb.Studio.StudioBetaBodyOnceTest do
  @moduledoc """
  Beta binds a richText field named `body` once (task-9f230ad6d5b50fb0).

  With no stored layout, the derived layout used to carry a `body` field row
  AND the trailing `body` region, so Beta showed the same text twice: a
  textarea row and the block editor below it, writing two shapes to one key.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "bodyonce",
          "title" => "Utgivelse",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "body", "title" => "Tekst", "type" => "richText"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        "bodyonce",
        %{
          "doc_id" => "bodyonce-1",
          "title" => "Fjellet",
          "content" => %{"title" => "Fjellet", "body" => "<p>Once upon a mountain</p>"}
        },
        @dataset
      )

    :ok
  end

  test "Beta shows the body once, in the block editor", %{conn: conn} do
    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/bodyonce/bodyonce-1"))

    html = view |> element(~s([data-test-id="editor-mode-beta"])) |> render_click()

    assert html =~ ~s(data-test-id="studio-doc-beta-editor")

    doc = LazyHTML.from_document(html)

    assert doc |> LazyHTML.query(~s([data-test-id="paper-field-field-text"])) |> Enum.count() == 0,
           "a field row still binds body beside the region"

    assert length(String.split(html, "Once upon a mountain")) - 1 == 1,
           "the body text renders in more than one editor"
  end
end
