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
    |> put_req_header("x-bp-search-record", "1")
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

  # Regression for stw10-backlog-suggestions-recent-scope. The live capture: a
  # tokenless caller replaying a known `x-bp-search-client` value read the
  # OWNER's recent queries verbatim, because the header was consulted before the
  # token and so BOTH callers resolved to the same `client:<id>` bucket. The
  # header may now only subdivide the identity a request already proved.
  test "a spoofed client header does not read the token holder's recent bucket", %{conn: conn} do
    conn
    |> put_req_header("x-bp-search-client", "studio-picker")
    |> put_req_header("x-bp-search-record", "1")
    |> authed()
    |> get(~p"/v1/data/search/production?q=Suggest")
    |> json_response(200)

    # Owner still sees its own recents (the header subdivides its token bucket).
    owner =
      conn
      |> put_req_header("x-bp-search-client", "studio-picker")
      |> authed()
      |> get(~p"/v1/data/search/production/suggestions")
      |> json_response(200)

    assert Enum.any?(owner["result"]["recent"], &(&1["query"] == "Suggest"))

    # Tokenless attacker replaying the very same client id: no recents at all.
    spoofed =
      conn
      |> put_req_header("x-bp-search-client", "studio-picker")
      |> get(~p"/v1/data/search/production/suggestions")
      |> json_response(200)

    assert spoofed["result"]["recent"] == []

    # A DIFFERENT token holder replaying the same client id: also nothing.
    Auth.create_token("other-token", "dev", "v1-data-suggest-other", ["read"])

    other =
      conn
      |> put_req_header("x-bp-search-client", "studio-picker")
      |> put_req_header("authorization", "Bearer other-token")
      |> get(~p"/v1/data/search/production/suggestions")
      |> json_response(200)

    assert other["result"]["recent"] == []
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

  test "interaction records click against search event", %{conn: conn} do
    search =
      conn
      |> put_req_header("x-bp-search-client", "studio-picker")
      |> put_req_header("x-bp-search-record", "1")
      |> authed()
      |> get(~p"/v1/data/search/production?q=Suggest")
      |> json_response(200)

    search_id = search["searchEventId"]
    assert is_binary(search_id)

    interaction =
      conn
      |> put_req_header("x-bp-search-client", "studio-picker")
      |> authed()
      |> post(~p"/v1/data/search/production/interaction", %{
        "queryEventId" => search_id,
        "objectId" => "doc-suggest-1",
        "position" => 0,
        "type" => "select"
      })
      |> json_response(200)

    assert interaction["ok"] == true
    assert is_binary(interaction["interactionEventId"])

    click =
      Repo.get_by(Event,
        surface: "documents",
        event_type: "select",
        object_id: "doc-suggest-1",
        query_event_id: search_id
      )

    assert click
  end
end
