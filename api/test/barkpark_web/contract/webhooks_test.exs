defmodule BarkparkWeb.Contract.WebhooksTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  test "full CRUD lifecycle", %{conn: conn} do
    # Create
    resp =
      conn
      |> authed()
      |> post(
        "/v1/webhooks/test",
        Jason.encode!(%{
          name: "My Hook",
          url: "http://example.com/webhook",
          events: ["create", "publish"],
          types: ["post"]
        })
      )

    assert resp.status == 201
    body = Jason.decode!(resp.resp_body)
    id = body["webhook"]["id"]
    assert body["webhook"]["name"] == "My Hook"

    # List
    resp = conn |> authed() |> get("/v1/webhooks/test")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert length(body["webhooks"]) == 1

    # Show
    resp = conn |> authed() |> get("/v1/webhooks/test/#{id}")
    assert resp.status == 200

    # Update
    resp = conn |> authed() |> put("/v1/webhooks/test/#{id}", Jason.encode!(%{active: false}))
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["webhook"]["active"] == false

    # Delete
    resp = conn |> authed() |> delete("/v1/webhooks/test/#{id}")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert body["deleted"] == id

    # Verify deleted
    resp = conn |> authed() |> get("/v1/webhooks/test/#{id}")
    assert resp.status == 404
  end

  test "requires admin auth", %{conn: conn} do
    resp = get(conn, "/v1/webhooks/test")
    assert resp.status == 401
  end

  test "validates webhook creation", %{conn: conn} do
    resp = conn |> authed() |> post("/v1/webhooks/test", Jason.encode!(%{name: "Bad"}))
    assert resp.status == 422
  end
end
