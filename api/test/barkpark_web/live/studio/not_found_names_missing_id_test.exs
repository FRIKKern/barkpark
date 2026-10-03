defmodule BarkparkWeb.Studio.NotFoundNamesMissingIdTest do
  @moduledoc """
  The "Studio could not open this document" card must name the id that is
  missing. Found dogfooding: `/studio/post/post-all/p4` for a deleted p4 said
  "No post with the id post-all exists" — the id of the All list, not p4.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @dataset "production"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} = Content.create_document("post", %{"doc_id" => "p1", "title" => "One"}, @dataset)
    :ok
  end

  test "a missing document under the All list is named by its own id", %{conn: conn} do
    {:ok, _view, html} = live(conn, scoped_studio("/d/#{@dataset}/studio/post/post-all/p404"))
    IO.puts(inspect(Regex.run(~r/No post with the id.{0,200}/s, html)))
    assert html =~ ~r{No post with the id\s*<code>p404</code>}
  end
end
