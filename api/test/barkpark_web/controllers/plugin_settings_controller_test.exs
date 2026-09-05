defmodule BarkparkWeb.PluginSettingsControllerTest do
  @moduledoc """
  Contract tests for `/v1/plugins/settings/:plugin_name`.

  Covers:
    * 401 with no token
    * 403 with junior (non-admin) token
    * 200 round-trip with admin token (PUT then GET returns masked secret)
    * 404 after DELETE
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Plugins.Settings

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

    test "errors use the canonical envelope (code + request_id), not a bare string", %{conn: conn} do
      resp = conn |> admin_conn() |> get("/v1/plugins/settings/does-not-exist")
      body = json_response(resp, 404)
      # error is an OBJECT keyed by code + a request_id for log correlation —
      # NOT the old bare `%{"error" => "not_found"}`.
      assert body["error"]["code"] == "not_found"
      assert body["error"]["message"] == "plugin settings not found"
      assert is_binary(body["error"]["request_id"])

      # 400 (missing `settings` key) is canonical too — was a bare string.
      bad = conn |> admin_conn() |> put("/v1/plugins/settings/x", Jason.encode!(%{wrong: "x"}))
      assert json_response(bad, 400)["error"]["code"] == "malformed"
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

  describe "mask round-trip protection (#849 twin)" do
    # show/2 masks every string leaf, so re-submitting the GET body verbatim
    # would overwrite the real secret with the mask literal without this guard.
    test "re-submitting a masked GET body keeps the stored secret intact", %{conn: conn} do
      put_body = Jason.encode!(%{settings: %{"api_key" => "secret-value-wxyz", "ratio" => 0.5}})

      assert conn
             |> admin_conn()
             |> put("/v1/plugins/settings/onixedit", put_body)
             |> Map.get(:status) == 200

      # GET returns the masked view.
      masked =
        conn
        |> admin_conn()
        |> get("/v1/plugins/settings/onixedit")
        |> Map.get(:resp_body)
        |> Jason.decode!()

      assert get_in(masked, ["settings", "api_key"]) == "********wxyz"

      # PUT the masked body back verbatim (the documented edit-one-field flow).
      round_trip = Jason.encode!(%{settings: masked["settings"]})

      assert conn
             |> admin_conn()
             |> put("/v1/plugins/settings/onixedit", round_trip)
             |> Map.get(:status) == 200

      # The raw secret survives — the mask literal was NOT persisted.
      assert {:ok, stored} = Settings.get("onixedit")
      assert stored["api_key"] == "secret-value-wxyz"
      assert stored["ratio"] == 0.5
    end

    test "a freshly typed secret (≠ mask) is persisted", %{conn: conn} do
      first = Jason.encode!(%{settings: %{"api_key" => "old-secret-wxyz"}})

      assert conn
             |> admin_conn()
             |> put("/v1/plugins/settings/onixedit", first)
             |> Map.get(:status) == 200

      # A new value that does not equal the mask must overwrite the stored one.
      typed = Jason.encode!(%{settings: %{"api_key" => "brand-new-abcd"}})

      assert conn
             |> admin_conn()
             |> put("/v1/plugins/settings/onixedit", typed)
             |> Map.get(:status) == 200

      assert {:ok, stored} = Settings.get("onixedit")
      assert stored["api_key"] == "brand-new-abcd"
    end

    test "key additions and removals are respected", %{conn: conn} do
      first =
        Jason.encode!(%{settings: %{"api_key" => "secret-value-wxyz", "drop_me" => "gone1234"}})

      assert conn
             |> admin_conn()
             |> put("/v1/plugins/settings/onixedit", first)
             |> Map.get(:status) == 200

      masked =
        conn
        |> admin_conn()
        |> get("/v1/plugins/settings/onixedit")
        |> Map.get(:resp_body)
        |> Jason.decode!()

      # Keep api_key masked (untouched), drop drop_me, add a new key.
      next =
        masked["settings"]
        |> Map.delete("drop_me")
        |> Map.put("region", "eu-north-1")

      assert conn
             |> admin_conn()
             |> put("/v1/plugins/settings/onixedit", Jason.encode!(%{settings: next}))
             |> Map.get(:status) == 200

      assert {:ok, stored} = Settings.get("onixedit")
      # Untouched masked key restored to raw.
      assert stored["api_key"] == "secret-value-wxyz"
      # Removed key is gone (full-map replace).
      refute Map.has_key?(stored, "drop_me")
      # New key persisted as typed.
      assert stored["region"] == "eu-north-1"
    end
  end
end
