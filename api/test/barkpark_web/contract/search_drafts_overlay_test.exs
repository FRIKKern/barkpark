defmodule BarkparkWeb.Contract.SearchDraftsOverlayTest do
  @moduledoc """
  Owner ruling #52 (2026-10-03; task-84b5e02e0b6b4006): search's
  `?perspective=drafts` is the draft-over-published overlay, the meaning the
  query and doc reads already give it. Before the ruling it meant drafts ONLY,
  so a client that passed one perspective to both surfaces never found a
  published document in search.

  The seed covers the four overlay cases, all matching "quokka" somewhere:

    * `plain`  — published, no draft            → the published row
    * `edited` — published, then its draft edited → the draft row only (dedup)
    * `fresh`  — draft only, never published      → the draft row
    * `moved`  — published "quokka", draft no longer mentions it → nothing:
                 the overlay picks the draft, and the draft does not match
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  @ds "search-drafts-overlay"

  setup do
    Auth.create_token("barkpark-dev-token", "dev", @ds, ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    publish = fn id, title ->
      {:ok, _} =
        Content.create_document("post", %{"doc_id" => "drafts." <> id, "title" => title}, @ds)

      {:ok, _} = Content.publish_document(id, "post", @ds)
    end

    draft = fn id, title ->
      {:ok, _} =
        Content.create_document("post", %{"doc_id" => "drafts." <> id, "title" => title}, @ds)
    end

    publish.("plain", "Quokka Plain Published")
    publish.("edited", "Quokka Edited Published")
    draft.("edited", "Quokka Edited Draft")
    draft.("fresh", "Quokka Fresh Draft")
    publish.("moved", "Quokka Moved Published")
    draft.("moved", "Wallaby Moved Draft")
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  defp search(conn, path, params) do
    resp = conn |> authed() |> get(path, params)
    assert resp.status == 200
    Jason.decode!(resp.resp_body)
  end

  @overlay ["Quokka Edited Draft", "Quokka Fresh Draft", "Quokka Plain Published"]

  test "/v1/data/search?perspective=drafts returns the overlay, one row per document", %{
    conn: conn
  } do
    body = search(conn, "/v1/data/search/#{@ds}", %{"q" => "quokka", "perspective" => "drafts"})
    titles = body["documents"] |> Enum.map(& &1["title"]) |> Enum.sort()

    assert titles == @overlay
    assert body["count"] == 3
  end

  test "federated /v1/search?perspective=drafts returns the same overlay", %{conn: conn} do
    body =
      search(conn, "/v1/search/#{@ds}", %{
        "q" => "quokka",
        "surfaces" => "documents",
        "perspective" => "drafts"
      })

    titles =
      body
      |> get_in(["results", "documents", "hits"])
      |> List.wrap()
      |> Enum.map(& &1["title"])
      |> Enum.sort()

    assert titles == @overlay
  end

  test "the overlay matches what the query endpoint lists for ?perspective=drafts", %{
    conn: conn
  } do
    listed =
      conn
      |> authed()
      |> get("/v1/data/query/#{@ds}/post?perspective=drafts")
      |> json_response(200)
      |> get_in(["result", "documents"])
      |> Enum.map(& &1["title"])
      |> Enum.filter(&String.contains?(&1, "Quokka"))
      |> Enum.sort()

    assert listed == @overlay
  end

  test "published and raw are unchanged", %{conn: conn} do
    published =
      search(conn, "/v1/data/search/#{@ds}", %{"q" => "quokka", "perspective" => "published"})

    assert published["documents"] |> Enum.map(& &1["title"]) |> Enum.sort() ==
             ["Quokka Edited Published", "Quokka Moved Published", "Quokka Plain Published"]

    raw = search(conn, "/v1/data/search/#{@ds}", %{"q" => "quokka", "perspective" => "raw"})
    assert raw["count"] == 5
  end
end
