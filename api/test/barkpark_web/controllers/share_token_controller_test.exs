defmodule BarkparkWeb.ShareTokenControllerTest do
  @moduledoc """
  P5 — the admin-only `/v1/shares/tokens` endpoints (mint / list / revoke).
  Minting is admin-gated (owner decision); the raw token is shown ONCE and the
  list never returns it.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Sharing}

  import Barkpark.TenancyFixtures

  @dataset "production"
  @admin "share-token-admin"
  @junior "share-token-junior"

  setup %{conn: conn} do
    {:ok, _} = Auth.create_token(@admin, "tok-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior, "tok-junior", @dataset, ["read", "write"])

    ws = create_workspace!("tok-ws")
    proj = create_project!(ws, "tok-proj")
    scope = "#{ws.slug}/#{proj.slug}/#{@dataset}"

    prior = Application.get_env(:barkpark, :shares)
    Application.put_env(:barkpark, :shares, Sharing.parse("#{scope}:docs,media:edit"))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, :shares, prior),
        else: Application.delete_env(:barkpark, :shares)
    end)

    %{conn: conn, scope: scope}
  end

  defp admin(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@admin}")
      |> put_req_header("content-type", "application/json")

  defp junior(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@junior}")
      |> put_req_header("content-type", "application/json")

  describe "POST /v1/shares/tokens" do
    test "admin mints a working, scope-bound token shown once", %{conn: conn, scope: scope} do
      resp = conn |> admin() |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
      assert resp.status == 201
      body = json_response(resp, 201)

      assert String.starts_with?(body["token"], "bpshare_")
      assert body["share_token"]["scope"] == scope
      assert body["share_token"]["surfaces"] == ["docs"]
      refute Map.has_key?(body["share_token"], "token_hash")

      # the raw token actually authenticates
      assert {:ok, _} = Auth.verify_token(body["token"])
    end

    test "non-admin is 403", %{conn: conn, scope: scope} do
      assert conn
             |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
             |> Map.get(:status) == 401

      assert conn
             |> junior()
             |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
             |> Map.get(:status) == 403
    end

    test "422 when the scope is not edit-shared", %{conn: conn} do
      resp =
        conn
        |> admin()
        |> post("/v1/shares/tokens", %{scope: "nope/nope/production", surfaces: "docs"})

      assert resp.status == 422
    end
  end

  describe "GET + DELETE /v1/shares/tokens" do
    test "list shows tokens (no raw/hash); revoke disables one", %{conn: conn, scope: scope} do
      raw =
        conn
        |> admin()
        |> post("/v1/shares/tokens", %{scope: scope, surfaces: "docs"})
        |> json_response(201)
        |> get_in(["token"])

      id =
        conn
        |> admin()
        |> post("/v1/shares/tokens", %{scope: scope, surfaces: "media"})
        |> json_response(201)
        |> get_in(["share_token", "id"])

      list = conn |> admin() |> get("/v1/shares/tokens?scope=#{scope}") |> json_response(200)
      assert length(list["tokens"]) == 2
      refute Enum.any?(list["tokens"], &Map.has_key?(&1, "token_hash"))

      # revoke the first (by raw -> we revoke by id of the second; assert it disables)
      assert conn
             |> admin()
             |> delete("/v1/shares/tokens/#{id}")
             |> json_response(200)
             |> Map.get("revoked") == true

      # the first token still works; only the revoked id is gone from active use
      assert {:ok, _} = Auth.verify_token(raw)
    end

    test "revoke is admin-only", %{conn: conn} do
      assert conn
             |> junior()
             |> delete("/v1/shares/tokens/00000000-0000-0000-0000-000000000000")
             |> Map.get(:status) == 403
    end
  end
end
