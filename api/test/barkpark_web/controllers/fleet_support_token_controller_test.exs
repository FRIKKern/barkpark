defmodule BarkparkWeb.FleetSupportTokenControllerTest do
  @moduledoc """
  Contract tests for `/v1/fleet/support-tokens` (Personal Dev Fleet Wave C —
  PDF-D57/D60).

  Covers: 401 no token, 403 non-admin (both ends of the admin gate), the 201
  mint shape + one-time secret + WRITE capability + `fleet-support-<name>` label,
  and the revoke lifecycle — an HTTP request authenticated with the revoked token
  is rejected AFTERWARD (proven from a live auth attempt, never assumed from the
  DELETE 200), plus 404 on an unknown id.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  @admin_token "barkpark-test-fleet-support-admin"
  @junior_token "barkpark-test-fleet-support-junior"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "fleet-support-admin", "test", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "fleet-support-junior", "test", ["read", "write"])
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

  defp mint(conn, name) do
    conn
    |> admin_conn()
    |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: name}))
  end

  describe "auth gating" do
    test "POST mint returns 401 without a token", %{conn: conn} do
      body = Jason.encode!(%{name: "laptop"})

      assert conn
             |> put_req_header("content-type", "application/json")
             |> post("/v1/fleet/support-tokens", body)
             |> Map.get(:status) == 401
    end

    test "POST mint returns 403 for a non-admin token", %{conn: conn} do
      body = Jason.encode!(%{name: "laptop"})

      assert conn |> junior_conn() |> post("/v1/fleet/support-tokens", body) |> Map.get(:status) ==
               403
    end

    test "DELETE returns 401 without a token", %{conn: conn} do
      assert delete(conn, "/v1/fleet/support-tokens/whatever").status == 401
    end
  end

  describe "mint" do
    test "returns 201 with {token, token_id, name} and mints a WRITE-capable token", %{conn: conn} do
      resp = mint(conn, "build-box")
      assert resp.status == 201
      payload = Jason.decode!(resp.resp_body)

      assert payload["name"] == "build-box"
      assert is_binary(payload["token"]) and byte_size(payload["token"]) > 0
      assert is_binary(payload["token_id"]) and byte_size(payload["token_id"]) > 0

      # The returned secret is a live, WRITE-capable credential (PDF-D57: fleet
      # verbs are bearer-only, so the support must hold write).
      assert {:ok, token} = Auth.verify_token(payload["token"])
      assert token.id == payload["token_id"]
      assert Auth.has_permission?(token, "write")
      assert Auth.has_permission?(token, "read")
      # But NOT admin — a support can never mint more tokens.
      refute Auth.has_permission?(token, "admin")
      # Label convention.
      assert token.label == "fleet-support-build-box"
    end

    test "the secret is returned exactly once (never echoed on a second mint)", %{conn: conn} do
      first = mint(conn, "box-a") |> Map.get(:resp_body) |> Jason.decode!()
      second = mint(conn, "box-b") |> Map.get(:resp_body) |> Jason.decode!()

      # Each mint yields its OWN distinct secret + id — there is no retrieval path.
      assert first["token"] != second["token"]
      assert first["token_id"] != second["token_id"]
    end

    test "422 when name is missing or blank", %{conn: conn} do
      assert conn
             |> admin_conn()
             |> post("/v1/fleet/support-tokens", Jason.encode!(%{}))
             |> Map.get(:status) == 422

      assert conn
             |> admin_conn()
             |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: "   "}))
             |> Map.get(:status) == 422
    end
  end

  describe "revoke" do
    test "a request authenticated with the revoked token is REJECTED afterward", %{conn: conn} do
      minted = mint(conn, "teardown-me") |> Map.get(:resp_body) |> Jason.decode!()
      raw = minted["token"]
      token_id = minted["token_id"]

      # Before revoke: the token is a VALID credential. It is non-admin, so an
      # admin-gated call passes RequireToken and fails RequireAdmin → 403.
      before =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: "x"}))

      assert before.status == 403
      assert {:ok, _} = Auth.verify_token(raw)

      # Revoke it.
      del = conn |> admin_conn() |> delete("/v1/fleet/support-tokens/#{token_id}")
      assert del.status == 200
      assert Jason.decode!(del.resp_body) == %{"token_id" => token_id, "revoked" => true}

      # After revoke: the SAME authenticated request is now rejected at
      # RequireToken → 401 (the credential is dead, not merely under-privileged).
      after_revoke =
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: "x"}))

      assert after_revoke.status == 401
      assert {:error, _} = Auth.verify_token(raw)
    end

    test "DELETE on an unknown/garbage id returns 404 (not 500)", %{conn: conn} do
      assert conn
             |> admin_conn()
             |> delete("/v1/fleet/support-tokens/not-a-real-id")
             |> Map.get(:status) == 404

      assert conn
             |> admin_conn()
             |> delete("/v1/fleet/support-tokens/#{Ecto.UUID.generate()}")
             |> Map.get(:status) == 404
    end
  end
end
