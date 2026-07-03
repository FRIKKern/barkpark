defmodule BarkparkWeb.Contract.WebhooksTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Webhooks

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

  test "reenable restores an auto-disabled endpoint to a clean deliverable state", %{conn: conn} do
    # Create an endpoint.
    resp =
      conn
      |> authed()
      |> post(
        "/v1/webhooks/test",
        Jason.encode!(%{
          name: "Flaky Hook",
          url: "http://example.com/webhook",
          events: ["publish"],
          types: ["post"]
        })
      )

    assert resp.status == 201
    id = Jason.decode!(resp.resp_body)["webhook"]["id"]

    # Drive terminal failures past the threshold so the endpoint auto-disables.
    for _ <- 0..Webhooks.auto_disable_threshold() do
      Webhooks.record_endpoint_failure(id, "connection refused")
    end

    resp = conn |> authed() |> get("/v1/webhooks/test/#{id}")
    body = Jason.decode!(resp.resp_body)
    assert body["webhook"]["active"] == false
    assert body["webhook"]["consecutive_failures"] > Webhooks.auto_disable_threshold()
    refute is_nil(body["webhook"]["auto_disabled_at"])
    refute is_nil(body["webhook"]["disable_reason"])

    # Re-enable via the recovery route.
    resp = conn |> authed() |> post("/v1/webhooks/test/#{id}/reenable")
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    # Fresh budget: active AND the failure streak reset (so it won't re-disable
    # after a single further terminal failure).
    assert body["webhook"]["active"] == true
    assert body["webhook"]["consecutive_failures"] == 0
    assert is_nil(body["webhook"]["auto_disabled_at"])
    assert is_nil(body["webhook"]["disable_reason"])

    # One more terminal failure must NOT re-disable it — proves the reset gave a
    # genuine fresh budget rather than leaving it one strike from death.
    Webhooks.record_endpoint_failure(id, "connection refused")
    resp = conn |> authed() |> get("/v1/webhooks/test/#{id}")
    body = Jason.decode!(resp.resp_body)
    assert body["webhook"]["active"] == true
    assert body["webhook"]["consecutive_failures"] == 1
  end

  test "reenable on an unknown webhook id is not found", %{conn: conn} do
    resp =
      conn
      |> authed()
      |> post("/v1/webhooks/test/#{Ecto.UUID.generate()}/reenable")

    assert resp.status == 404
  end
end
