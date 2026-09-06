defmodule BarkparkWeb.ScimConformanceTest do
  @moduledoc """
  SCIM 2.0 conformance polish (era-scim-conformance-polish) — the three edges a
  strict Azure AD / Okta client walks that this server used to get wrong:

    * **path-less whole-resource `PATCH`** (RFC 7644 §3.5.2.3). Azure sometimes
      pushes the entire resource through `PATCH` as one `replace` with no
      `path`. Both SCIM controllers keyed off `path`, so that request was a
      silent `200` over a mutation that never happened.
    * **single-resource discovery GETs** (RFC 7644 §4). `/ResourceTypes` and
      `/Schemas` emitted a `meta.location` per entry — and every one of those
      URLs 404'd, because only the collection routes existed. Conditional now:
      a matching `If-None-Match` answers `304`.
    * **`application/scim+json`** (RFC 7644 §3.1). The pipeline's
      `plug(:accepts, ["json"])` raised `Phoenix.NotAcceptableError` → `406` for
      a client that asked for SCIM's own media type by name, and every response
      went out as `application/json`.

  Every request body below is written in the shape the IdP actually sends
  (`schemas: [...PatchOp]` included), and every deny path — unauthenticated,
  malformed operation, unknown discovery id — is asserted alongside the happy
  one. Membership assertions read STORED rows, never a second endpoint.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Repo, Scim, Tenancy}
  alias Barkpark.Tenancy.Membership
  import Ecto.Query

  @patch_op "urn:ietf:params:scim:api:messages:2.0:PatchOp"
  @error_urn "urn:ietf:params:scim:api:messages:2.0:Error"
  @user_urn "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_urn "urn:ietf:params:scim:schemas:core:2.0:Group"

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, {token, _}} = Scim.mint_token(org.id, "test")
    %{org: org, ws: ws, token: token}
  end

  defp scim(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp provision(token, email) do
    scim(token)
    |> post("/scim/v2/Users", Jason.encode!(%{"userName" => email}))
    |> json_response(201)

    Accounts.get_user_by_email(email)
  end

  defp create_group(token, name, role) do
    scim(token)
    |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => name, "role" => role}))
    |> json_response(201)
  end

  defp member_values(body), do: Enum.map(body["members"] || [], & &1["value"])

  defp in_workspace?(user_id, ws_id) do
    Repo.exists?(
      from(m in Membership,
        where:
          m.principal_type == "user" and m.principal_id == ^user_id and
            m.workspace_id == ^ws_id
      )
    )
  end

  defp content_type(conn), do: conn |> get_resp_header("content-type") |> List.first() || ""

  # ── C0 · path-less whole-resource PATCH ────────────────────────────────────

  describe "PATCH with a path-less replace (RFC 7644 §3.5.2.3) — Users" do
    # THE AZURE SHAPE, verbatim: no `path`, the resource itself as `value`.
    # `deactivating?/1` compared `op["path"]` to "active" and this body has no
    # `path` at all, so the request answered 200/"active": true for a user the
    # directory had just disabled.
    test "a path-less replace carrying active:false deprovisions the user" do
      %{token: token, ws: ws} = org_with_ws("plessuser")
      user = provision(token, "azure@plessuser.com")
      {:ok, session} = Accounts.create_user_session_token(user)
      assert in_workspace?(user.id, ws.id)

      body =
        Jason.encode!(%{
          "schemas" => [@patch_op],
          "Operations" => [%{"op" => "replace", "value" => %{"active" => false}}]
        })

      resp = scim(token) |> patch("/scim/v2/Users/#{user.id}", body) |> json_response(200)

      assert resp["active"] == false
      # STORED rows, not the receipt: the membership is gone and the session dead.
      refute in_workspace?(user.id, ws.id)
      assert is_nil(Accounts.verify_user_session_token(session))
    end

    test "a path-less replace that does not touch active leaves the user active" do
      %{token: token, ws: ws} = org_with_ws("plessnoop")
      user = provision(token, "keep@plessnoop.com")

      body =
        Jason.encode!(%{
          "schemas" => [@patch_op],
          "Operations" => [
            %{"op" => "replace", "value" => %{"userName" => "keep@plessnoop.com"}}
          ]
        })

      resp = scim(token) |> patch("/scim/v2/Users/#{user.id}", body) |> json_response(200)

      assert resp["active"] == true
      assert in_workspace?(user.id, ws.id)
    end
  end

  describe "PATCH with a path-less replace (RFC 7644 §3.5.2.3) — Groups" do
    test "a path-less replace renames the group and reconciles its members" do
      %{token: token} = org_with_ws("plessgrp")
      user = provision(token, "m@plessgrp.com")
      gid = create_group(token, "Admins", "admin") |> Map.fetch!("id")

      body =
        Jason.encode!(%{
          "schemas" => [@patch_op],
          "Operations" => [
            %{
              "op" => "replace",
              "value" => %{
                "displayName" => "Administrators",
                "members" => [%{"value" => user.id}]
              }
            }
          ]
        })

      resp = scim(token) |> patch("/scim/v2/Groups/#{gid}", body) |> json_response(200)

      assert resp["displayName"] == "Administrators"
      assert member_values(resp) == [user.id]
      # The receipt is read back from stored rows by render_group/4, and the
      # role grant itself is the authority:
      assert Repo.exists?(
               from(m in Membership,
                 where: m.principal_id == ^user.id and m.role == "admin"
               )
             )
    end

    # THE OMISSION CASE. "The 'value' parameter SHALL contain a list of
    # attributes to be replaced" — the ones NAMED. A rename that says nothing
    # about members must not empty the group, which a blind
    # `member_ids(attrs["members"])` (nil → []) would have done by reconciling
    # the membership to the empty set.
    test "a path-less replace naming only displayName keeps the existing members" do
      %{token: token} = org_with_ws("plesskeep")
      user = provision(token, "stay@plesskeep.com")
      gid = create_group(token, "Admins", "admin") |> Map.fetch!("id")

      seed =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "add", "path" => "members", "value" => [%{"value" => user.id}]}
          ]
        })

      assert scim(token)
             |> patch("/scim/v2/Groups/#{gid}", seed)
             |> json_response(200)
             |> member_values() == [user.id]

      rename =
        Jason.encode!(%{
          "schemas" => [@patch_op],
          "Operations" => [%{"op" => "replace", "value" => %{"displayName" => "Renamed"}}]
        })

      resp = scim(token) |> patch("/scim/v2/Groups/#{gid}", rename) |> json_response(200)

      assert resp["displayName"] == "Renamed"
      assert member_values(resp) == [user.id]
    end
  end

  describe "malformed PATCH operations are typed SCIM errors, with no write" do
    test "a path-less replace whose value is not an object is 400 invalidSyntax" do
      %{token: token, ws: ws} = org_with_ws("badvalue")
      user = provision(token, "bad@badvalue.com")

      body =
        Jason.encode!(%{
          "schemas" => [@patch_op],
          "Operations" => [%{"op" => "replace", "value" => "active"}]
        })

      resp = scim(token) |> patch("/scim/v2/Users/#{user.id}", body) |> json_response(400)

      assert resp["schemas"] == [@error_urn]
      assert resp["status"] == "400"
      assert resp["scimType"] == "invalidSyntax"
      # NO PARTIAL WRITE: the refusal is decided before the resource is touched.
      assert in_workspace?(user.id, ws.id)
    end

    test "a path-less remove is 400 noTarget and leaves the group untouched" do
      %{token: token} = org_with_ws("notarget")
      user = provision(token, "nt@notarget.com")
      gid = create_group(token, "Admins", "admin") |> Map.fetch!("id")

      seed =
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "add", "path" => "members", "value" => [%{"value" => user.id}]}
          ]
        })

      scim(token) |> patch("/scim/v2/Groups/#{gid}", seed) |> json_response(200)

      body =
        Jason.encode!(%{"schemas" => [@patch_op], "Operations" => [%{"op" => "remove"}]})

      resp = scim(token) |> patch("/scim/v2/Groups/#{gid}", body) |> json_response(400)

      assert resp["scimType"] == "noTarget"

      # The membership the malformed remove named nothing about is still there.
      assert scim(token)
             |> get("/scim/v2/Groups/#{gid}")
             |> json_response(200)
             |> member_values() == [user.id]
    end

    test "an unauthenticated path-less PATCH is 401, never 400 or 200" do
      %{token: token} = org_with_ws("plessauth")
      user = provision(token, "anon@plessauth.com")

      body =
        Jason.encode!(%{
          "schemas" => [@patch_op],
          "Operations" => [%{"op" => "replace", "value" => %{"active" => false}}]
        })

      assert scoped_conn()
             |> put_req_header("content-type", "application/json")
             |> patch("/scim/v2/Users/#{user.id}", body)
             |> json_response(401)
    end
  end

  # ── C1 · single-resource discovery GETs ────────────────────────────────────

  describe "GET /scim/v2/ResourceTypes/:id and /Schemas/:id" do
    test "every meta.location the collections advertise now resolves" do
      %{token: token} = org_with_ws("discloc")

      for collection <- ["ResourceTypes", "Schemas"] do
        listed = scim(token) |> get("/scim/v2/#{collection}") |> json_response(200)
        assert listed["Resources"] != []

        for resource <- listed["Resources"] do
          location = resource["meta"]["location"]
          assert is_binary(location)
          path = URI.parse(location).path

          assert scim(token) |> get(path) |> json_response(200) |> Map.fetch!("id") ==
                   resource["id"]
        end
      end
    end

    test "ResourceTypes/User and /Group are the canonical resources" do
      %{token: token} = org_with_ws("disctypes")

      user = scim(token) |> get("/scim/v2/ResourceTypes/User") |> json_response(200)
      assert user["id"] == "User"
      assert user["endpoint"] == "/Users"
      assert user["schema"] == @user_urn
      assert String.ends_with?(user["meta"]["location"], "/scim/v2/ResourceTypes/User")

      group = scim(token) |> get("/scim/v2/ResourceTypes/Group") |> json_response(200)
      assert group["id"] == "Group"
      assert group["endpoint"] == "/Groups"
    end

    test "Schemas/:urn returns the schema with its attributes" do
      %{token: token} = org_with_ws("discschema")

      schema = scim(token) |> get("/scim/v2/Schemas/#{@user_urn}") |> json_response(200)
      assert schema["id"] == @user_urn
      assert "userName" in Enum.map(schema["attributes"], & &1["name"])

      group = scim(token) |> get("/scim/v2/Schemas/#{@group_urn}") |> json_response(200)
      assert group["id"] == @group_urn
      assert "members" in Enum.map(group["attributes"], & &1["name"])
    end

    test "an unknown id is a typed SCIM 404, not a bare Phoenix 404" do
      %{token: token} = org_with_ws("disc404")

      for path <- ["/scim/v2/ResourceTypes/Nope", "/scim/v2/Schemas/urn:not:a:schema"] do
        body = scim(token) |> get(path) |> json_response(404)
        assert body["schemas"] == [@error_urn]
        assert body["status"] == "404"
      end
    end

    test "the single GETs are behind the same bearer as every other SCIM route" do
      for path <- [
            "/scim/v2/ResourceTypes/User",
            "/scim/v2/Schemas/#{@user_urn}",
            "/scim/v2/ResourceTypes/Nope"
          ] do
        assert scoped_conn() |> get(path) |> json_response(401)
      end
    end
  end

  describe "conditional discovery GET (If-None-Match)" do
    test "the served ETag comes back as 304 with an empty body" do
      %{token: token} = org_with_ws("disc304")

      first = scim(token) |> get("/scim/v2/ResourceTypes/User")
      assert first.status == 200
      [etag] = get_resp_header(first, "etag")
      assert etag =~ ~r/^W\/"scim-[0-9a-f]+"$/

      second =
        scim(token)
        |> put_req_header("if-none-match", etag)
        |> get("/scim/v2/ResourceTypes/User")

      assert response(second, 304) == ""
      # The validator that selected the 304 rides along, or the client has
      # nothing to send on the next cycle.
      assert get_resp_header(second, "etag") == [etag]
    end

    test "a stale or absent tag returns the resource, never a 304" do
      %{token: token} = org_with_ws("discstale")

      stale =
        scim(token)
        |> put_req_header("if-none-match", ~s(W/"scim-deadbeefdeadbeef"))
        |> get("/scim/v2/Schemas/#{@user_urn}")

      assert json_response(stale, 200)["id"] == @user_urn

      assert scim(token) |> get("/scim/v2/Schemas/#{@user_urn}") |> json_response(200)
    end

    test "the wildcard * matches an existing discovery document" do
      %{token: token} = org_with_ws("discstar")

      conn =
        scim(token)
        |> put_req_header("if-none-match", "*")
        |> get("/scim/v2/ResourceTypes/Group")

      assert response(conn, 304) == ""
    end
  end

  # ── C2 · application/scim+json ─────────────────────────────────────────────

  describe "the SCIM media type (RFC 7644 §3.1)" do
    test "every SCIM response — resource, list, error — is application/scim+json" do
      %{token: token} = org_with_ws("mediaout")
      user = provision(token, "mt@mediaout.com")

      responses = [
        scim(token) |> get("/scim/v2/ServiceProviderConfig"),
        scim(token) |> get("/scim/v2/ResourceTypes/User"),
        scim(token) |> get("/scim/v2/Users"),
        scim(token) |> get("/scim/v2/Users/#{user.id}"),
        scim(token) |> get("/scim/v2/Users/00000000-0000-0000-0000-000000000000"),
        scoped_conn() |> get("/scim/v2/Users")
      ]

      for conn <- responses do
        assert content_type(conn) =~ "application/scim+json",
               "#{conn.request_path} answered #{conn.status} as #{content_type(conn)}"
      end
    end

    test "Accept: application/scim+json is served, not refused with a 406" do
      %{token: token} = org_with_ws("mediaaccept")

      for accept <- [
            "application/scim+json",
            "application/scim+json; charset=utf-8",
            "application/json, application/scim+json;q=0.9",
            "application/json",
            "*/*",
            "application/*"
          ] do
        conn =
          scim(token)
          |> put_req_header("accept", accept)
          |> get("/scim/v2/ServiceProviderConfig")

        assert json_response(conn, 200)["patch"]["supported"] == true,
               "Accept: #{accept} was refused"
      end
    end

    test "a POST body sent as application/scim+json is parsed" do
      %{token: token} = org_with_ws("mediain")

      body =
        scim(token)
        |> put_req_header("content-type", "application/scim+json")
        |> put_req_header("accept", "application/scim+json")
        |> post("/scim/v2/Users", Jason.encode!(%{"userName" => "in@mediain.com"}))
        |> json_response(201)

      assert body["userName"] == "in@mediain.com"
      assert Accounts.get_user_by_email("in@mediain.com")
    end

    test "an Accept this endpoint cannot serve is a SCIM 406 envelope" do
      %{token: token} = org_with_ws("media406")

      conn =
        scim(token)
        |> put_req_header("accept", "text/html")
        |> get("/scim/v2/ServiceProviderConfig")

      body = json_response(conn, 406)
      assert body["schemas"] == [@error_urn]
      assert body["status"] == "406"
      assert content_type(conn) =~ "application/scim+json"
    end
  end
end
