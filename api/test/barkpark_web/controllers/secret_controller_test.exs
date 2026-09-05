defmodule BarkparkWeb.SecretControllerTest do
  @moduledoc """
  Contract tests for `/v1/secrets`.

  Covers: 401 no token, 403 non-admin, admin reveal/set/list/delete lifecycle.
  Unlike plugin-settings, GET /:name REVEALS the unmasked value.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

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

  # ── secrets_audit read surface (connectors — two-tier audit log read) ──
  # The write-only `secrets_audit` log now has a read side: `GET
  # /v1/secrets/:name/audit`. Metadata only (never a secret value), newest
  # first, paginated, tenant-walled by the same D199 guard as every verb.
  describe "audit read surface (auth gating)" do
    test "GET audit returns 401 without a token", %{conn: conn} do
      assert get(conn, "/v1/secrets/api_key/audit").status == 401
    end

    test "GET audit returns 403 for a non-admin token", %{conn: conn} do
      assert conn |> junior_conn() |> get("/v1/secrets/api_key/audit") |> Map.get(:status) == 403
    end
  end

  describe "audit read surface (flat / global tier)" do
    test "audit trail records set + reveal actions, newest first, metadata only", %{conn: conn} do
      body = Jason.encode!(%{value: "trail-secret-0001"})

      assert conn |> admin_conn() |> put("/v1/secrets/audited_key", body) |> Map.get(:status) ==
               200

      # A reveal stamps its own audit row.
      assert conn |> admin_conn() |> get("/v1/secrets/audited_key") |> Map.get(:status) == 200

      resp = conn |> admin_conn() |> get("/v1/secrets/audited_key/audit")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["name"] == "audited_key"

      rows = payload["audit"]
      assert length(rows) == 2
      # Newest-first: the reveal was written after the set.
      assert Enum.map(rows, & &1["action"]) == ["reveal", "set"]

      # MASKED — metadata only; the plaintext (or any masked form of it) never
      # appears in the audit response.
      for row <- rows do
        refute Map.has_key?(row, "value")
        assert row["action"] in ["set", "reveal", "delete"]
        assert Map.has_key?(row, "inserted_at")
      end

      refute resp.resp_body =~ "trail-secret-0001"
    end

    test "audit for a delete outlives the secret — 200 with the delete row, not 404", %{
      conn: conn
    } do
      body = Jason.encode!(%{value: "ephemeral-2222"})
      assert conn |> admin_conn() |> put("/v1/secrets/gone_key", body) |> Map.get(:status) == 200
      assert conn |> admin_conn() |> delete("/v1/secrets/gone_key") |> Map.get(:status) == 200

      # The secret is gone, but its audit trail is not.
      assert conn |> admin_conn() |> get("/v1/secrets/gone_key") |> Map.get(:status) == 404

      resp = conn |> admin_conn() |> get("/v1/secrets/gone_key/audit")
      assert resp.status == 200
      actions = Jason.decode!(resp.resp_body)["audit"] |> Enum.map(& &1["action"])
      assert "delete" in actions
    end

    test "an untouched name returns an honest empty list, not a 404", %{conn: conn} do
      resp = conn |> admin_conn() |> get("/v1/secrets/never_touched_key/audit")
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["audit"] == []
    end

    test "limit is honored and bounded", %{conn: conn} do
      body = Jason.encode!(%{value: "paged-3333"})
      # set + 3 reveals = 4 rows.
      assert conn |> admin_conn() |> put("/v1/secrets/paged_key", body) |> Map.get(:status) == 200
      for _ <- 1..3, do: conn |> admin_conn() |> get("/v1/secrets/paged_key")

      resp = conn |> admin_conn() |> get("/v1/secrets/paged_key/audit?limit=2")
      assert resp.status == 200
      payload = Jason.decode!(resp.resp_body)
      assert payload["limit"] == 2
      assert length(payload["audit"]) == 2
    end
  end

  # Red-first: the audit read must obey the tenant wall. A workspace admin sees
  # ONLY their workspace's rows; the global tier never sees a workspace's rows,
  # and a foreign workspace's audit trail is an opaque empty list.
  describe "audit read surface — tenant wall (cross-tenant, red-first)" do
    setup do
      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "sec-audit-a", name: "Sec Audit A"})
      {:ok, _} = Tenancy.create_project(ws_a, %{slug: "default", name: "Default"})

      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "sec-audit-b", name: "Sec Audit B"})
      {:ok, _} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

      admin_a_raw = "sec-audit-admin-a-#{System.unique_integer([:positive])}"

      {:ok, tok_a} =
        Auth.create_token(admin_a_raw, "audit-admin-a", "test", ["read", "write", "admin"])

      {:ok, _} = TenancyAuth.create_membership(ws_a.id, tok_a.id, "admin")

      admin_b_raw = "sec-audit-admin-b-#{System.unique_integer([:positive])}"

      {:ok, tok_b} =
        Auth.create_token(admin_b_raw, "audit-admin-b", "test", ["read", "write", "admin"])

      {:ok, _} = TenancyAuth.create_membership(ws_b.id, tok_b.id, "admin")

      %{admin_a_raw: admin_a_raw, admin_b_raw: admin_b_raw}
    end

    defp scoped_conn(raw),
      do:
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")

    defp scoped_path(slug, rest), do: "/w/#{slug}/p/default/v1/secrets#{rest}"

    test "a workspace admin sees their OWN tier's audit rows (sanity — the wall is not a mute)",
         %{admin_a_raw: raw_a} do
      assert scoped_conn(raw_a)
             |> put(scoped_path("sec-audit-a", "/cross_probe"), Jason.encode!(%{value: "a-val"}))
             |> Map.get(:status) == 200

      resp = scoped_conn(raw_a) |> get(scoped_path("sec-audit-a", "/cross_probe/audit"))
      assert resp.status == 200
      actions = Jason.decode!(resp.resp_body)["audit"] |> Enum.map(& &1["action"])
      assert "set" in actions
    end

    test "ws-B admin's scoped audit read never sees ws-A's rows (opaque empty)", %{
      admin_a_raw: raw_a,
      admin_b_raw: raw_b
    } do
      assert scoped_conn(raw_a)
             |> put(scoped_path("sec-audit-a", "/cross_probe"), Jason.encode!(%{value: "a-val"}))
             |> Map.get(:status) == 200

      # ws-B reads the SAME name through their OWN scope → opaque empty, no leak.
      resp = scoped_conn(raw_b) |> get(scoped_path("sec-audit-b", "/cross_probe/audit"))
      assert resp.status == 200

      assert Jason.decode!(resp.resp_body)["audit"] == [],
             "ws-B's scoped audit read LEAKED ws-A's audit rows — CROSS-TENANT LEAK"
    end

    test "the flat/global audit read never sees a workspace's rows", %{
      admin_a_raw: raw_a,
      conn: conn
    } do
      assert scoped_conn(raw_a)
             |> put(scoped_path("sec-audit-a", "/cross_probe"), Jason.encode!(%{value: "a-val"}))
             |> Map.get(:status) == 200

      resp = conn |> admin_conn() |> get("/v1/secrets/cross_probe/audit")
      assert resp.status == 200

      assert Jason.decode!(resp.resp_body)["audit"] == [],
             "the global audit read LEAKED a workspace-scoped secret's audit rows"
    end
  end
end
