defmodule BarkparkWeb.SanityErrorBodyTest do
  # task-0db87287cc6fc325: on the Sanity-shaped read paths an error body also carries what
  # @sanity/client reads (error.description, top-level statusCode and message), so
  # ClientError.message names the cause. Barkpark's {error: {code, message, …}} stays.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "sanity-err", name: "Sanity err"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    token = "sanity-err-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "err", "production", ["read"], ws.id)
    %{token: token}
  end

  defp get_as(conn, token, path) do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, path)
  end

  test "missing dataset, bad token and no token: Sanity's fields beside Barkpark's", %{
    conn: conn,
    token: token
  } do
    for {tok, path, status} <- [
          {token, "/w/sanity-err/p/site/v2025-02-19/data/query/no-such-dataset?query=count(*)",
           404},
          {"bogus-token", "/w/sanity-err/p/site/v2025-02-19/data/query/production?query=count(*)",
           401},
          {nil, "/w/sanity-err/p/site/v2025-02-19/data/query/production?query=count(*)", 403}
        ] do
      resp = get_as(scoped_conn(), tok, path)
      assert resp.status == status, path
      body = json_response(resp, status)

      assert %{"code" => code, "message" => message, "description" => message} = body["error"]
      assert is_binary(code) and message != ""
      assert body["statusCode"] == status
      assert body["message"] == message
    end

    _ = conn
  end

  test "a Barkpark-only path keeps its body exactly as before", %{token: token} do
    resp =
      get_as(scoped_conn(), "bogus-token", "/w/sanity-err/p/site/v1/data/search/production?q=x")

    body = json_response(resp, 401)
    assert body["error"]["code"] == "unauthorized"
    refute Map.has_key?(body, "statusCode")
    refute Map.has_key?(body["error"], "description")
  end
end
