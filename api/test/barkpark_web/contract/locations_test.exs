defmodule BarkparkWeb.Contract.LocationsTest do
  @moduledoc """
  "Used on N pages" (Studio J62, task-c5d5e045e7efcc96) — `GET
  /v1/data/locations/:dataset/:id` resolves `backlinks/2`'s own list into
  readable consumer-site URLs via each backlink's own schema `desk.preview`
  template. Same fixture shape `backlinks_test.exs` uses (schema with a
  reference field, publish, materialise `content_edges` directly) plus the
  `desk.preview` template `studio_preview_link_action_test.exs` uses.
  """
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  @dataset "locations_test"
  @template "https://site.example/blog/:slug"

  defp seed_type(name, desk, extra_fields \\ []) do
    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => String.capitalize(name),
          "visibility" => "public",
          "desk" => desk,
          "fields" =>
            [
              %{"name" => "title", "title" => "Title", "type" => "string"},
              %{"name" => "slug", "title" => "Slug", "type" => "string"}
            ] ++ extra_fields
        },
        @dataset
      )
  end

  setup do
    Barkpark.Auth.create_token("locations-token", "dev", @dataset, ["read", "write", "admin"])

    seed_type("author", %{})

    seed_type("article", %{"preview" => @template}, [
      %{"name" => "author", "type" => "reference"}
    ])

    seed_type("note", %{}, [%{"name" => "author", "type" => "reference"}])

    {:ok, _} =
      Content.create_document("author", %{"_id" => "author-1", "title" => "Target"}, @dataset)

    {:ok, _} = Content.publish_document("author-1", "author", @dataset)

    :ok
  end

  defp publish_referencing!(type, id, title, extra_content \\ %{}) do
    {:ok, _} =
      Content.create_document(
        type,
        Map.merge(%{"_id" => id, "title" => title, "author" => "author-1"}, extra_content),
        @dataset
      )

    {:ok, _} = Content.publish_document(id, type, @dataset)

    Content.add_edges([%{from_id: id, to_id: "author-1", kind: "references"}], dataset: @dataset)
  end

  defp get_locations(conn, id, opts \\ []) do
    conn =
      if opts[:auth] == false,
        do: conn,
        else: put_req_header(conn, "authorization", "Bearer locations-token")

    get(conn, "/v1/data/locations/#{@dataset}/#{id}")
  end

  test "a backlink with a slug and a desk.preview template resolves to a URL", %{conn: conn} do
    publish_referencing!("article", "art-1", "Refs Target", %{"slug" => "my-article"})

    resp = get_locations(conn, "author-1")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)

    assert [loc] = body["result"]["locations"]
    assert loc["doc_id"] == "art-1"
    assert loc["type"] == "article"
    assert loc["title"] == "Refs Target"
    assert loc["url"] == "https://site.example/blog/my-article"
    assert body["result"]["count"] == 1
  end

  test "a backlink whose type declares no desk.preview template is omitted", %{conn: conn} do
    publish_referencing!("note", "note-1", "A note", %{"slug" => "a-note"})

    resp = get_locations(conn, "author-1")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)

    assert body["result"]["locations"] == []
    assert body["result"]["count"] == 0
  end

  test "a backlink needing :slug with no slug set is omitted, not a wrong URL", %{conn: conn} do
    publish_referencing!("article", "art-2", "Slugless")

    resp = get_locations(conn, "author-1")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)

    assert body["result"]["locations"] == []
  end

  test "a doc with no referencers returns an empty locations list", %{conn: conn} do
    resp = get_locations(conn, "author-1")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["result"]["locations"] == []
    assert body["result"]["count"] == 0
  end

  test "without a token, locations 404s (existence-hiding, like backlinks)", %{conn: conn} do
    resp = get_locations(conn, "author-1", auth: false)
    assert resp.status == 404
  end

  test "resolves on the SAME set backlinks returns (mixed templated + untemplated)", %{
    conn: conn
  } do
    publish_referencing!("article", "art-3", "Templated", %{"slug" => "templated-one"})
    publish_referencing!("note", "note-2", "Untemplated", %{"slug" => "untemplated-one"})

    backlinks_resp =
      conn
      |> put_req_header("authorization", "Bearer locations-token")
      |> get("/v1/data/backlinks/#{@dataset}/author-1")

    backlinks_body = Jason.decode!(backlinks_resp.resp_body)
    assert backlinks_body["result"]["count"] == 2

    locations_resp = get_locations(conn, "author-1")
    locations_body = Jason.decode!(locations_resp.resp_body)

    assert locations_body["result"]["count"] == 1
    assert [loc] = locations_body["result"]["locations"]
    assert loc["doc_id"] == "art-3"
  end
end
