defmodule BarkparkWeb.Integration.V1DataSearchSuggestionsTest do
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Search.Event
  alias Barkpark.Repo

  setup do
    Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "v1-data-suggest-test",
      ["read", "write", "admin"]
    )

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "production"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.doc-suggest-1", "title" => "Suggest Phoenix Guide"},
      "production"
    )

    Content.publish_document("doc-suggest-1", "post", "production")

    Repo.delete_all(from(e in Event, where: e.surface == "documents"))
    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer barkpark-dev-token")

  test "search records documents surface events and returns searchEventId", %{conn: conn} do
    body =
      conn
      |> authed()
      |> get(~p"/v1/data/search/production?q=Suggest")
      |> json_response(200)

    assert body["count"] >= 1
    assert is_binary(body["searchEventId"])

    assert Repo.get_by(Event, surface: "documents", scope: "production", query: "Suggest")
  end

  test "suggestions returns recent queries for client header", %{conn: conn} do
    conn
    |> put_req_header("x-bp-search-client", "studio-picker")
    |> authed()
    |> get(~p"/v1/data/search/production?q=Suggest")
    |> json_response(200)

    suggest =
      conn
      |> put_req_header("x-bp-search-client", "studio-picker")
      |> authed()
      |> get(~p"/v1/data/search/production/suggestions")
      |> json_response(200)

    recent = suggest["result"]["recent"]
    assert Enum.any?(recent, &(&1["query"] == "Suggest"))
  end

  test "insights requires admin token", %{conn: conn} do
    resp = get(conn, ~p"/v1/data/search/production/insights?period=week")
    assert resp.status == 401

    body =
      conn
      |> authed()
      |> get(~p"/v1/data/search/production/insights?period=week")
      |> json_response(200)

    assert body["result"]["surface"] == "documents"
    assert body["result"]["scope"] == "production"
  end
end
