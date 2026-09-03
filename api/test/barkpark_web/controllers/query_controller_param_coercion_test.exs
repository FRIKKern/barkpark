defmodule BarkparkWeb.QueryControllerParamCoercionTest do
  @moduledoc """
  Regression guard for `parse_expand/1` in `QueryController` (task
  `wbqs-api-query-param-coercion`).

  Phoenix's `Plug.Conn.Query` parser turns `?expand[]=author` into a LIST
  (`["author"]`) and `?expand[k]=v` into a MAP. `parse_expand/1` previously
  had clauses only for `nil`, `""`, `"false"`, `"true"`, and any other
  binary — no catch-all — so a list- or map-shaped `expand` param raised
  `FunctionClauseError` and Phoenix turned that into an HTTP 500 on the
  anonymously-reachable `GET /v1/data/query/:dataset/:type` route.

  This asserts the anonymous public-read route never 500s on a non-binary
  `expand` param, and that the ordinary binary-shaped `expand` still works.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @ds "query_param_coercion_test"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @ds
      )

    :ok
  end

  test "GET /v1/data/query/:dataset/:type — array ?expand[]=author stays < 500", %{conn: conn} do
    resp = get(conn, "/v1/data/query/#{@ds}/post", %{"expand" => ["author"]})
    refute resp.status == 500
    assert resp.status < 500
  end

  test "GET /v1/data/query/:dataset/:type — map ?expand[k]=v stays < 500", %{conn: conn} do
    resp = get(conn, "/v1/data/query/#{@ds}/post", %{"expand" => %{"k" => "author"}})
    refute resp.status == 500
    assert resp.status < 500
  end

  test "GET /v1/data/query/:dataset/:type — ordinary binary ?expand=author still works", %{
    conn: conn
  } do
    resp = get(conn, "/v1/data/query/#{@ds}/post", %{"expand" => "author"})
    assert resp.status == 200
  end
end
