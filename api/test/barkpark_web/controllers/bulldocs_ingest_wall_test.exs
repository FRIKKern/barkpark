defmodule BarkparkWeb.BulldocsIngestWallTest do
  @moduledoc """
  The ingest half of the D26 wall mount, kept OUT of
  `bulldocs_ingest_controller_test.exs` (the error-head rendering slice owns
  that file): a COMPLIANT tagged ingest POST publishes — the attrs whitelist
  threads `tags` + `description` through BOTH heads (blocks and legacy
  body_html), so an honest producer can pass the wall it is now held to.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  # Set in config/test.exs.
  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/papers"
  @dataset "production"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
  end

  defp labels do
    labels = LabelFixtures.paper_attrs(%{"dataset" => @dataset})
    %{"tags" => labels["tags"], "description" => labels["description"]}
  end

  defp title_block(text) do
    %{
      "id" => "tpl-title",
      "type" => "heading",
      "level" => 1,
      "role" => "title",
      "locked" => true,
      "text" => text
    }
  end

  test "a compliant tagged BLOCKS ingest POST publishes (tags + description thread through)", %{
    conn: conn
  } do
    slug = "ingest-wall-blocks-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = labels()

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => [
          title_block("Walled ingest paper"),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Honest ingest body content."}]
          }
        ],
        "tags" => tags,
        "description" => description
      })

    assert %{"ok" => true, "slug" => ^slug} = json_response(conn, 200)

    paper = Content.get_paper(slug, @dataset)
    assert paper.status == "published"
    assert paper.content["tags"] == tags
    assert paper.content["description"] == description
    # The shared stamp closes D7 for the paper birth path.
    [%{"tag" => strongest} | _] = tags
    assert paper.content["main_tag"] == strongest
  end

  test "a compliant tagged LEGACY body_html ingest POST publishes too (the second head)", %{
    conn: conn
  } do
    slug = "ingest-wall-html-#{System.unique_integer([:positive])}"
    %{"tags" => tags, "description" => description} = labels()

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "body_html" => "<article><h1>Legacy walled paper</h1><p>Real body.</p></article>",
        "tags" => tags,
        "description" => description
      })

    assert %{"ok" => true, "slug" => ^slug} = json_response(conn, 200)

    paper = Content.get_paper(slug, @dataset)
    assert paper.status == "published"
    assert paper.content["tags"] == tags
    assert paper.content["main_tag"] == hd(tags)["tag"]
  end

  test "a tagless ingest POST is refused — fresh ingest-born docs are never exempt (D6)", %{
    conn: conn
  } do
    slug = "ingest-wall-tagless-#{System.unique_integer([:positive])}"

    conn =
      authed(conn)
      |> post(@path, %{
        "slug" => slug,
        "blocks" => [
          title_block("Tagless ingest paper"),
          %{
            "id" => "p1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Body without labels."}]
          }
        ]
      })

    # The wall refuses BEFORE any write, and the controller's render_error head
    # (ae-ingest-honest-errors / D27) renders the SPECIFIC shape: a 422 whose
    # code is label_spine with a machine-actionable hint — the exact envelope a
    # producer retries against.
    resp = json_response(conn, 422)
    assert resp["error"]["code"] == "label_spine"
    assert is_binary(resp["error"]["hint"])
    refute Content.get_paper(slug, @dataset)
  end
end
