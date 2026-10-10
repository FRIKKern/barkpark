defmodule BarkparkWeb.Contract.MalformedFilterParamTest do
  @moduledoc """
  task-341a5d9e63ffdcc3: a malformed filter param on the data query API is a
  400 `invalid_filter` that names the offending param, never a 200 result set.

  `?filter[[=x` decodes (Plug) to a TOP-LEVEL `"filter[["` key. Nothing read it,
  so the request ran unfiltered and answered every document. The same happens to
  every broken bracket spelling (`filter[title=x`, `filter]=x`, `filter[a][eq=x`).
  Inside a well-formed `filter` map, a field that is blank or carries a bracket
  (`filter[%20]=x`, `filter[a]]=x`) is malformed too.

  Real router, real DB, both the flat and the workspace-scoped route. Every
  malformed shape must answer 400 with `details.param`; the controls prove a
  well-formed filter still narrows and an unrelated param is still ignored.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content

  @ds "mfp_http"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, title} <- [{"m1", "Alpha"}, {"m2", "Beta"}, {"m3", "Gamma"}] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => title}, @ds)
      {:ok, _} = Content.publish_document(id, "post", @ds)
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()

    # The scoped door refuses an anonymous caller (403), so it is read with a
    # read token bound to the workspace; the flat door is read anonymously.
    raw = "mfp-#{System.unique_integer([:positive])}"
    {:ok, _} = Barkpark.Auth.create_token(raw, "mfp", @ds, ["read"], ws.id)

    %{
      routes: [
        {"/v1/data/query/#{@ds}/post", nil},
        {"/w/#{ws.slug}/p/#{proj.slug}/v1/data/query/#{@ds}/post", raw}
      ]
    }
  end

  defp request({path, token}, query) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, path <> "?" <> query)
  end

  # {raw query string, the param the refusal must name}
  @malformed [
    {"filter[[=x", "filter[["},
    {"filter%5B%5B=x", "filter[["},
    {"filter[=x", "filter["},
    {"filter[title=Alpha", "filter[title"},
    {"filter]=x", "filter]"},
    {"filter[title][eq=Alpha", "filter[title][eq"},
    {"filter[title]]=Alpha", "filter[title]]"},
    {"filter[%20]=Alpha", "filter[ ]"},
    {"filter[]]=Alpha", "filter[]]"}
  ]

  for {query, param} <- @malformed do
    test "#{query} is a 400 naming #{param}, on the flat and the scoped route", ctx do
      for route <- ctx.routes do
        conn = request(route, unquote(query))

        assert conn.status == 400,
               "#{elem(route, 0)}?#{unquote(query)} answered #{conn.status}: #{String.slice(conn.resp_body, 0, 300)}"

        %{"error" => error} = Jason.decode!(conn.resp_body)
        assert error["code"] == "invalid_filter"
        assert error["details"]["param"] == unquote(param)
      end
    end
  end

  test "an unknown operator still refuses on the scoped route (existing guard, both doors)",
       ctx do
    for route <- ctx.routes do
      conn = request(route, "filter[title][bogus]=x")
      assert conn.status == 400, "#{elem(route, 0)} answered #{conn.status}"
    end
  end

  test "control: a well-formed filter still narrows, on both routes", ctx do
    for route <- ctx.routes do
      %{"result" => body} =
        route |> request("filter[title][eq]=Alpha") |> json_response(200)

      assert body["count"] == 1
    end
  end

  test "control: an unrelated param is not a filter and is still ignored", ctx do
    for route <- ctx.routes do
      %{"result" => body} = route |> request("filters=x&fil=1") |> json_response(200)
      assert body["count"] == 3
    end
  end
end
