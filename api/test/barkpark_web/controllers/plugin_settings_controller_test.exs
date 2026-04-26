defmodule BarkparkWeb.PluginSettingsControllerTest do
  @moduledoc """
  Contract tests for `/v1/plugins/settings/:plugin_name`.

  Covers:
    * 401 with no token
    * 403 with junior (non-admin) token
    * 200 round-trip with admin token (PUT then GET returns masked secret)
    * 404 after DELETE
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @admin_token "barkpark-test-admin-token"
  @junior_token "barkpark-test-junior-token"

  setup do
    {:ok, _admin} =
      Auth.create_token(@admin_token, "test-admin", "test", ["read", "write", "admin"])

    {:ok, _junior} = Auth.create_token(@junior_token, "test-junior", "test", ["read", "write"])
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
    test "GET returns 401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/plugins/settings/onixedit")
      assert resp.status == 401
    end

    test "GET returns 403 for non-admin token", %{conn: conn} do
      resp = conn |> junior_conn() |> get("/v1/plugins/settings/onixedit")
      assert resp.status == 403
    end

    test "PUT returns 403 for non-admin token", %{conn: conn} do
      body = Jason.encode!(%{settings: %{"api_key" => "abcdwxyz"}})
      resp = conn |> junior_conn() |> put("/v1/plugins/settings/onixedit", body)
      assert resp.status == 403
    end

    test "DELETE returns 403 for non-admin token", %{conn: conn} do
      resp = conn |> junior_conn() |> delete("/v1/plugins/settings/onixedit")
      assert resp.status == 403
    end
  end

  describe "admin lifecycle" do
    test "GET on missing plugin returns 404", %{conn: conn} do
      resp = conn |> admin_conn() |> get("/v1/plugins/settings/does-not-exist")
      assert resp.status == 404
    end

    test "PUT then GET returns masked secret (last 4 visible)", %{conn: conn} do
      body = Jason.encode!(%{settings: %{"api_key" => "secret-value-wxyz", "ratio" => 0.5}})
      resp = conn |> admin_conn() |> put("/v1/plugins/settings/onixedit", body)
      assert resp.status == 200

      resp = conn |> admin_conn() |> get("/v1/plugins/settings/onixedit")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["plugin_name"] == "onixedit"
      assert get_in(payload, ["settings", "api_key"]) == "********wxyz"
      assert get_in(payload, ["settings", "ratio"]) == 0.5
    end

    test "PUT then DELETE → subsequent GET returns 404", %{conn: conn} do
      body = Jason.encode!(%{settings: %{"api_key" => "abcdEFGH"}})
      resp = conn |> admin_conn() |> put("/v1/plugins/settings/onixedit", body)
      assert resp.status == 200

      resp = conn |> admin_conn() |> delete("/v1/plugins/settings/onixedit")
      assert resp.status == 200

      resp = conn |> admin_conn() |> get("/v1/plugins/settings/onixedit")
      assert resp.status == 404
    end

    test "PUT without `settings` key returns 400", %{conn: conn} do
      body = Jason.encode!(%{wrong: "shape"})
      resp = conn |> admin_conn() |> put("/v1/plugins/settings/onixedit", body)
      assert resp.status == 400
    end
  end
end
