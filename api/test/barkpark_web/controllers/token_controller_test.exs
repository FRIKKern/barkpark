defmodule BarkparkWeb.TokenControllerTest do
  @moduledoc """
  Controller tests for the admin-gated read-only token mint
  (`POST /w/:ws/p/:project/v1/tokens`).

  The endpoint exists to mint the `public-read` token a new site needs (it
  replaces the ssh `mix run --no-start` mint — see templates/DEPLOYING.md). The
  invariants under test:

    * SCOPED-ADMIN GATE — only an owner/admin of the workspace can mint; a member
      (even one holding global admin perms) → 403; a non-member → 403; anonymous
      → 403/404.
    * READ-ONLY ALLOWLIST — the minted token reads published docs in the
      workspace but 403s on mutate; requesting write/admin permissions → 422
      with NO token issued.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "tok-mint-ws", name: "Token Mint WS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    # A published doc so the minted read token has something to read.
    {:ok, _doc} =
      Content.create_document(
        "post",
        %{"doc_id" => "hello-1", "title" => "Hello"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("hello-1", "post", @dataset, scope)

    # ADMIN of ws (legit minter).
    admin_raw = "tok-admin-#{System.unique_integer([:positive])}"

    {:ok, admin_token} =
      Auth.create_token(admin_raw, "admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_token.id, "admin")

    # MEMBER of ws holding global admin perms — must NOT be able to mint.
    member_raw = "tok-member-#{System.unique_integer([:positive])}"

    {:ok, member_token} =
      Auth.create_token(member_raw, "member", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, member_token.id)

    # NON-MEMBER with global admin perms — no membership in ws.
    nonmember_raw = "tok-nonmember-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(nonmember_raw, "nonmember", @dataset, ["read", "write", "admin"])

    {:ok, ws: ws, admin_raw: admin_raw, member_raw: member_raw, nonmember_raw: nonmember_raw}
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp mint(conn, raw, body) do
    conn
    |> authed(raw)
    |> post("/w/tok-mint-ws/p/default/v1/tokens", Jason.encode!(body))
  end

  describe "admin mint (happy path)" do
    test "workspace admin mints a public-read token (201, token present)", %{
      conn: conn,
      admin_raw: raw
    } do
      resp = mint(conn, raw, %{"label" => "public-read-site", "permissions" => ["public-read"]})
      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)

      assert is_binary(body["token"]) and byte_size(body["token"]) > 0
      assert body["label"] == "public-read-site"
      assert body["permissions"] == ["public-read"]
      assert body["dataset"] == "production"
      assert body["workspace"] == "tok-mint-ws"
    end

    test "the minted token READS published docs and is 403 on mutate", %{
      conn: conn,
      admin_raw: raw
    } do
      minted =
        mint(conn, raw, %{"label" => "public-read-site"})
        |> Map.get(:resp_body)
        |> Jason.decode!()
        |> Map.fetch!("token")

      # READ: the minted token holds a membership row for the workspace, so the
      # tenancy gate passes and it sees the published doc.
      read =
        conn
        |> put_req_header("authorization", "Bearer " <> minted)
        |> get("/w/tok-mint-ws/p/default/v1/data/query/#{@dataset}/post?filter[status]=published")
        |> json_response(200)

      ids = read |> get_in(["result", "documents"]) |> Enum.map(& &1["_id"])
      assert "hello-1" in ids

      # MUTATE: read-only token has no write perm → 403.
      write =
        conn
        |> authed(minted)
        |> post(
          "/w/tok-mint-ws/p/default/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{"mutations" => []})
        )

      assert write.status == 403
    end

    test "defaults permissions to public-read and dataset to production", %{
      conn: conn,
      admin_raw: raw
    } do
      resp = mint(conn, raw, %{"label" => "defaults"})
      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)
      assert body["permissions"] == ["public-read"]
      assert body["dataset"] == "production"
    end
  end

  describe "scoped-admin gate" do
    test "a member of the workspace (global admin perms) → 403", %{conn: conn, member_raw: raw} do
      resp = mint(conn, raw, %{"label" => "x", "permissions" => ["public-read"]})
      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "a non-member (global admin perms) → 403", %{conn: conn, nonmember_raw: raw} do
      resp = mint(conn, raw, %{"label" => "x", "permissions" => ["public-read"]})
      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "anonymous → 403/404 (no token)", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/w/tok-mint-ws/p/default/v1/tokens",
          Jason.encode!(%{"label" => "x", "permissions" => ["public-read"]})
        )

      assert resp.status in [401, 403, 404]
    end
  end

  describe "read-only allowlist (no privilege-mint)" do
    test "requesting [\"write\"] → 422, no token issued", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{"label" => "x", "permissions" => ["write"]})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unprocessable"
    end

    test "requesting [\"admin\"] → 422", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{"label" => "x", "permissions" => ["admin"]})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unprocessable"
    end

    test "requesting [\"ops\"] → 422", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{"label" => "x", "permissions" => ["ops"]})
      assert resp.status == 422
    end

    test "mixing public-read with write → 422 (the write entry is rejected)", %{
      conn: conn,
      admin_raw: raw
    } do
      resp = mint(conn, raw, %{"label" => "x", "permissions" => ["public-read", "write"]})
      assert resp.status == 422
    end

    test "[\"read\"] is allowed (read is in the allowlist)", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{"label" => "read-tok", "permissions" => ["read"]})
      assert resp.status == 201
      assert Jason.decode!(resp.resp_body)["permissions"] == ["read"]
    end
  end

  describe "validation" do
    test "missing label → 422", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{"permissions" => ["public-read"]})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unprocessable"
    end

    test "blank label → 422", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{"label" => "   ", "permissions" => ["public-read"]})
      assert resp.status == 422
    end

    # The module comment above `fetch_permissions/1` promises that a bad
    # `permissions` value "collapses to the forbidden path". `is_list/1` only
    # checks the CONTAINER, so a list of maps used to reach `to_string/1` and
    # raise Protocol.UndefinedError (String.Chars is not implemented for Map) —
    # a 500 where the contract says 422. Elements must be checked too.
    test "permissions as a list of MAPS → 422 :invalid, never a 500", %{
      conn: conn,
      admin_raw: raw
    } do
      resp =
        mint(conn, raw, %{
          "label" => "perm-map-#{System.unique_integer([:positive])}",
          "permissions" => [%{"a" => "b"}]
        })

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "unprocessable"
      assert body["error"]["message"] =~ ":invalid"
    end

    test "permissions as a list of INTEGERS → 422 :invalid (not a stringified perm)", %{
      conn: conn,
      admin_raw: raw
    } do
      resp =
        mint(conn, raw, %{
          "label" => "perm-int-#{System.unique_integer([:positive])}",
          "permissions" => [1, 2]
        })

      assert resp.status == 422
      body = Jason.decode!(resp.resp_body)
      assert body["error"]["code"] == "unprocessable"
      # NOT `["1", "2"]` — a non-binary element is invalid by SHAPE, so both
      # non-string element kinds land on the same deterministic envelope.
      assert body["error"]["message"] =~ ":invalid"
    end
  end
end
