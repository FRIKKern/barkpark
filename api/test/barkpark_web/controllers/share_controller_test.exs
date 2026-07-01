defmodule BarkparkWeb.ShareControllerTest do
  @moduledoc """
  P4b — contract tests for `/v1/shares`, the admin-only sharing registry CRUD
  behind `bp share ls/add/rm`.

  Covers:
    * auth gating — 401 anon, 403 non-admin, 200 admin on every verb
    * add upserts a stored share and makes it live (shared?/4)
    * add rejects an invalid scope/surface (422, no row)
    * rm removes a stored share and refreshes the live list
    * ls reports both the env baseline and stored shares, tagged by source

  `async: false`: the registry lives in the process-global `:barkpark, :shares`
  / `:shares_env` env, restored on_exit.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Sharing}

  @admin_token "barkpark-test-admin-share"
  @junior_token "barkpark-test-junior-share"

  setup do
    {:ok, _} = Auth.create_token(@admin_token, "share-admin", "test", ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior_token, "share-junior", "test", ["read", "write"])

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp admin_conn(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin_token)
    |> put_req_header("content-type", "application/json")
  end

  defp junior_conn(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @junior_token)
    |> put_req_header("content-type", "application/json")
  end

  # ── auth gating ─────────────────────────────────────────────────────────

  describe "auth gating" do
    test "GET /v1/shares is 401 anon, 403 junior, 200 admin", %{conn: conn} do
      assert get(conn, "/v1/shares").status == 401
      assert get(junior_conn(conn), "/v1/shares").status == 403
      assert get(admin_conn(conn), "/v1/shares").status == 200
    end

    test "POST /v1/shares is 401 anon, 403 junior", %{conn: conn} do
      body = %{scope: "gyldendal/default/production", surfaces: "papers"}
      assert post(conn, "/v1/shares", body).status == 401
      assert post(junior_conn(conn), "/v1/shares", body).status == 403
      # the rejected writes never persisted a share
      refute Sharing.shared?("gyldendal", "default", "production", :papers)
    end

    test "DELETE /v1/shares is 401 anon, 403 junior", %{conn: conn} do
      assert delete(conn, "/v1/shares", %{scope: "x"}).status == 401
      assert delete(junior_conn(conn), "/v1/shares", %{scope: "x"}).status == 403
    end
  end

  describe "canonical error envelope" do
    test "validation (422) and not_found (404) are code + request_id objects, not bare strings",
         %{conn: conn} do
      # Missing scope → 422. Was a bare `%{"error" => "scope is required"}`;
      # now a keyable code + the human message + a request_id.
      bad = conn |> admin_conn() |> post("/v1/shares", %{surfaces: "papers"})
      body = json_response(bad, 422)
      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["message"] == "scope is required"
      assert is_binary(body["error"]["request_id"])

      # Revoking a nonexistent share-edit token → 404 canonical envelope.
      nf = conn |> admin_conn() |> delete("/v1/shares/tokens/11111111-1111-1111-1111-111111111111")
      nfb = json_response(nf, 404)
      assert nfb["error"]["code"] == "not_found"
      assert nfb["error"]["message"] == "token not found"
      assert is_binary(nfb["error"]["request_id"])
    end

    test "a malformed (non-UUID) token id is a clean 404, not an Ecto CastError 500", %{conn: conn} do
      # revoke_token queries ApiToken by :binary_id; before the UUID-cast guard a
      # garbage id raised Ecto.CastError → 500. Now it's a canonical 404.
      resp = conn |> admin_conn() |> delete("/v1/shares/tokens/not-a-uuid")
      assert json_response(resp, 404)["error"]["code"] == "not_found"
    end
  end

  # ── add (POST) ──────────────────────────────────────────────────────────

  describe "POST /v1/shares" do
    test "creates a share and it goes live immediately", %{conn: conn} do
      body = %{scope: "gyldendal/books/production", surfaces: "papers,docs", access: "read"}

      resp = conn |> admin_conn() |> post("/v1/shares", body)
      assert resp.status == 201
      assert %{"share" => share} = json_response(resp, 201)
      assert share["source"] == "stored"
      assert Enum.sort(share["surfaces"]) == ["docs", "papers"]

      assert Sharing.shared?("gyldendal", "books", "production", :papers)
      assert Sharing.shared?("gyldendal", "books", "production", :docs)
    end

    test "defaults access to read and scope project/dataset", %{conn: conn} do
      resp = conn |> admin_conn() |> post("/v1/shares", %{scope: "gyldendal", surfaces: "papers"})
      assert resp.status == 201

      assert Sharing.access_for("gyldendal", "default", "production") == :read
    end

    test "edit access is honored", %{conn: conn} do
      body = %{scope: "g/p/production", surfaces: "media", access: "edit"}
      assert (conn |> admin_conn() |> post("/v1/shares", body)).status == 201
      assert Sharing.access_for("g", "p", "production") == :edit
    end

    test "422 on a wildcard scope, no share created", %{conn: conn} do
      resp =
        conn |> admin_conn() |> post("/v1/shares", %{scope: "*/p/production", surfaces: "papers"})

      assert resp.status == 422
      refute Sharing.shared?("*", "p", "production", :papers)
    end

    test "422 when surfaces are all unknown", %{conn: conn} do
      resp =
        conn |> admin_conn() |> post("/v1/shares", %{scope: "g/p/production", surfaces: "wat"})

      assert resp.status == 422
    end

    test "422 when scope is missing", %{conn: conn} do
      resp = conn |> admin_conn() |> post("/v1/shares", %{surfaces: "papers"})
      assert resp.status == 422
    end
  end

  # ── rm (DELETE) ─────────────────────────────────────────────────────────

  describe "DELETE /v1/shares" do
    test "removes a stored share and refreshes the live list", %{conn: conn} do
      assert {:ok, _} = Sharing.add_share("gyldendal/books/production:papers:read")
      assert Sharing.shared?("gyldendal", "books", "production", :papers)

      resp = conn |> admin_conn() |> delete("/v1/shares", %{scope: "gyldendal/books/production"})
      assert resp.status == 200
      assert %{"removed" => 1} = json_response(resp, 200)

      refute Sharing.shared?("gyldendal", "books", "production", :papers)
    end

    test "removing an absent scope returns removed: 0", %{conn: conn} do
      resp = conn |> admin_conn() |> delete("/v1/shares", %{scope: "nobody/here/production"})
      assert %{"removed" => 0} = json_response(resp, 200)
    end
  end

  # ── ls (GET) ────────────────────────────────────────────────────────────

  describe "GET /v1/shares" do
    test "reports env baseline + stored, each tagged by source", %{conn: conn} do
      Application.put_env(:barkpark, :shares_env, Sharing.parse("env-ws:papers:read"))
      assert {:ok, _} = Sharing.add_share("db-ws/default/production:docs:edit")

      body = conn |> admin_conn() |> get("/v1/shares") |> json_response(200)

      assert body["active"] == true
      sources = body["shares"] |> Enum.group_by(& &1["source"])
      assert [%{"workspace" => "env-ws"}] = sources["env"]
      assert [%{"workspace" => "db-ws", "access" => "edit"}] = sources["stored"]
    end

    test "empty when nothing is shared (default-off)", %{conn: conn} do
      body = conn |> admin_conn() |> get("/v1/shares") |> json_response(200)
      assert body == %{"shares" => [], "active" => false}
    end
  end
end
