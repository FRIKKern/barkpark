defmodule BarkparkWeb.SecretControllerTest do
  @moduledoc """
  Contract tests for `/v1/secrets`.

  Covers: 401 no token, 403 non-admin, admin reveal/set/list/delete lifecycle.
  Unlike plugin-settings, GET /:name REVEALS the unmasked value.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @admin_token "barkpark-test-secret-admin"
  @junior_token "barkpark-test-secret-junior"

  setup do
    {:ok, _} = Auth.create_token(@admin_token, "secret-admin", "test", ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior_token, "secret-junior", "test", ["read", "write"])
    :ok
  end

  defp admin_conn(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> @admin_token)
      |> put_req_header("content-type", "application/json")

  defp junior_conn(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> @junior_token)
      |> put_req_header("content-type", "application/json")

  describe "auth gating" do
    test "GET list returns 401 without a token", %{conn: conn} do
      assert get(conn, "/v1/secrets").status == 401
    end

    test "GET reveal returns 403 for non-admin token", %{conn: conn} do
      assert conn |> junior_conn() |> get("/v1/secrets/ingest_token") |> Map.get(:status) == 403
    end

    test "PUT returns 403 for non-admin token", %{conn: conn} do
      body = Jason.encode!(%{value: "abc"})

      assert conn |> junior_conn() |> put("/v1/secrets/ingest_token", body) |> Map.get(:status) ==
               403
    end
  end

  describe "admin lifecycle" do
    test "PUT then GET reveals the UNMASKED value", %{conn: conn} do
      body = Jason.encode!(%{value: "secret-value-wxyz"})
      assert conn |> admin_conn() |> put("/v1/secrets/api_key", body) |> Map.get(:status) == 200

      resp = conn |> admin_conn() |> get("/v1/secrets/api_key")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["name"] == "api_key"
      # The reveal point: unmasked, not "********wxyz".
      assert payload["value"] == "secret-value-wxyz"
    end

    test "list returns masked values", %{conn: conn} do
      body = Jason.encode!(%{value: "another-secret-1234"})
      assert conn |> admin_conn() |> put("/v1/secrets/db_pw", body) |> Map.get(:status) == 200

      resp = conn |> admin_conn() |> get("/v1/secrets")
      assert resp.status == 200
      secrets = Jason.decode!(resp.resp_body)["secrets"]
      row = Enum.find(secrets, &(&1["name"] == "db_pw"))
      assert row["value"] == "********1234"
    end

    test "GET on missing secret returns 404", %{conn: conn} do
      assert conn |> admin_conn() |> get("/v1/secrets/nope") |> Map.get(:status) == 404
    end

    test "errors use the canonical envelope (code + request_id), not a bare string", %{conn: conn} do
      resp = conn |> admin_conn() |> get("/v1/secrets/nope")
      assert resp.status == 404
      body = json_response(resp, 404)
      # Canonical shape: error is an OBJECT with a machine-keyable code + a
      # request_id for log correlation — NOT the old bare `%{"error" => "not_found"}`.
      assert body["error"]["code"] == "not_found"
      assert body["error"]["message"] == "secret not found"
      assert is_binary(body["error"]["request_id"])

      # 400 (missing value) is canonical too.
      bad = conn |> admin_conn() |> put("/v1/secrets/temp", Jason.encode!(%{wrong: "x"}))
      assert json_response(bad, 400)["error"]["code"] == "malformed"
    end

    test "PUT then DELETE → subsequent GET returns 404", %{conn: conn} do
      body = Jason.encode!(%{value: "tmpsecret"})
      assert conn |> admin_conn() |> put("/v1/secrets/temp", body) |> Map.get(:status) == 200
      assert conn |> admin_conn() |> delete("/v1/secrets/temp") |> Map.get(:status) == 200
      assert conn |> admin_conn() |> get("/v1/secrets/temp") |> Map.get(:status) == 404
    end

    test "PUT without a value key returns 400", %{conn: conn} do
      body = Jason.encode!(%{wrong: "shape"})
      assert conn |> admin_conn() |> put("/v1/secrets/temp", body) |> Map.get(:status) == 400
    end
  end
end
