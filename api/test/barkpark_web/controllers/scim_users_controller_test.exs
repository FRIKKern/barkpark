defmodule BarkparkWeb.ScimUsersControllerTest do
  @moduledoc "SCIM 2.0 /scim/v2/Users — provision + instant deprovision (era-w4-scim-users)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Auth, Repo, Scim, Tenancy}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy.Membership
  import Ecto.Query

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, {token, _}} = Scim.mint_token(org.id, "test")
    %{org: org, ws: ws, token: token}
  end

  defp scim(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp provision(token, email),
    do: scim(token) |> post("/scim/v2/Users", Jason.encode!(%{"userName" => email}))

  describe "POST /scim/v2/Users — provision" do
    test "provisions a confirmed user who can then log in (via magic-link)" do
      %{token: token, ws: ws} = org_with_ws("acme")

      resp = provision(token, "alice@acme.com") |> json_response(201)
      assert resp["userName"] == "alice@acme.com"
      assert resp["active"] == true

      user = Accounts.get_user_by_email("alice@acme.com")
      assert user
      refute is_nil(user.confirmed_at)
      # member of the org's workspace
      assert Repo.exists?(
               from m in Membership,
                 where:
                   m.principal_type == "user" and m.principal_id == ^user.id and
                     m.workspace_id == ^ws.id
             )

      # "can then log in": the passwordless path mints a session
      {:ok, plaintext, _} = Accounts.build_login_token("alice@acme.com")
      assert {:ok, logged_in} = Accounts.consume_login_token(plaintext)
      assert logged_in.id == user.id
    end

    test "emits a user_provisioned audit event" do
      %{token: token, org: org} = org_with_ws("audit-prov")
      provision(token, "b@audit-prov.com") |> json_response(201)

      ev = Repo.one(from e in Event, where: e.action == "user_provisioned")
      assert ev.category == "membership"
      assert ev.metadata["organization_id"] == org.id
    end

    test "400 when userName is missing" do
      %{token: token} = org_with_ws("badreq")
      assert scim(token) |> post("/scim/v2/Users", Jason.encode!(%{})) |> json_response(400)
    end
  end

  describe "instant deprovision (the enterprise hard-req)" do
    test "DELETE revokes ALL sessions + membership + audits" do
      %{token: token, ws: ws} = org_with_ws("deprov")
      provision(token, "gone@deprov.com") |> json_response(201)
      user = Accounts.get_user_by_email("gone@deprov.com")
      {:ok, session} = Accounts.create_user_session_token(user)
      id = user.id

      assert scim(token) |> delete("/scim/v2/Users/#{id}") |> response(204)

      # session dead
      assert is_nil(Accounts.verify_user_session_token(session))
      # membership gone
      refute Repo.exists?(
               from m in Membership,
                 where: m.principal_id == ^id and m.workspace_id == ^ws.id
             )

      # audited
      assert Repo.exists?(from e in Event, where: e.action == "user_deprovisioned")
    end

    test "PATCH active:false deprovisions (soft: revokes access, keeps the row)" do
      %{token: token, ws: ws} = org_with_ws("softdeprov")
      provision(token, "soft@softdeprov.com") |> json_response(201)
      user = Accounts.get_user_by_email("soft@softdeprov.com")
      {:ok, session} = Accounts.create_user_session_token(user)

      body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
        })

      resp = scim(token) |> patch("/scim/v2/Users/#{user.id}", body) |> json_response(200)
      assert resp["active"] == false

      assert is_nil(Accounts.verify_user_session_token(session))

      refute Repo.exists?(
               from m in Membership,
                 where: m.principal_id == ^user.id and m.workspace_id == ^ws.id
             )

      # soft: the user row survives
      assert Accounts.get_user(user.id)
    end
  end

  # era-w8: a killed session was not enough — a deprovisioned user who minted a
  # Personal Access Token (owner_user_id == user.id) kept a LIVE bearer, because
  # verify_token/1 never reads owner_user_id. Deprovision now stamps revoked_at on
  # every owner-bound PAT, BEFORE the hard-delete nilifies owner_user_id.
  describe "deprovision revokes owner-bound PATs (era-w8 runtime leak)" do
    # Mint a PAT hard-bound to `user` in `ws` (the session-gated self-mint shape).
    defp owner_pat(user, ws) do
      {:ok, {raw, token}} =
        Auth.create_personal_access_token("device", ["read"],
          role: "member",
          workspace_id: ws.id,
          owner_user_id: user.id
        )

      {raw, token}
    end

    test "DELETE (hard) revokes the PAT — verify_token → {:error, :unauthorized}" do
      %{token: scim_token, ws: ws} = org_with_ws("pat-hard")
      provision(scim_token, "hard@pat-hard.com") |> json_response(201)
      user = Accounts.get_user_by_email("hard@pat-hard.com")
      {raw, pat} = owner_pat(user, ws)

      # LIVE before deprovision (the leak precondition).
      assert {:ok, %ApiToken{id: pat_id}} = Auth.verify_token(raw)
      assert pat_id == pat.id

      assert scim(scim_token) |> delete("/scim/v2/Users/#{user.id}") |> response(204)

      # DENY-PATH: the raw PAT is dead the instant the user is deprovisioned.
      assert {:error, :unauthorized} = Auth.verify_token(raw)
      # revoked_at stamped BEFORE the FK nilified owner_user_id.
      assert %ApiToken{revoked_at: %DateTime{}} = Repo.get(ApiToken, pat.id)
    end

    test "PATCH active:false (soft) revokes the PAT — verify_token → {:error, :unauthorized}" do
      %{token: scim_token, ws: ws} = org_with_ws("pat-soft")
      provision(scim_token, "soft@pat-soft.com") |> json_response(201)
      user = Accounts.get_user_by_email("soft@pat-soft.com")
      {raw, _pat} = owner_pat(user, ws)

      assert {:ok, %ApiToken{}} = Auth.verify_token(raw)

      body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
        })

      assert scim(scim_token) |> patch("/scim/v2/Users/#{user.id}", body) |> json_response(200)

      # DENY-PATH: soft deprovision (row survives) still kills the PAT.
      assert {:error, :unauthorized} = Auth.verify_token(raw)
      assert Accounts.get_user(user.id)
    end

    test "the revoke is owner-scoped — a NON-owner (machine) token survives" do
      %{token: scim_token, ws: ws} = org_with_ws("pat-scoped")
      provision(scim_token, "keep@pat-scoped.com") |> json_response(201)
      user = Accounts.get_user_by_email("keep@pat-scoped.com")
      {owner_raw, _} = owner_pat(user, ws)

      # A machine token (owner_user_id NULL) — the shape a share-edit token also
      # takes (scope-keyed, never owner-bound). It must NOT be swept.
      {:ok, machine} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token("machine-raw-token"),
          permissions: ["read"],
          dataset: "production"
        })
        |> Repo.insert()

      assert scim(scim_token) |> delete("/scim/v2/Users/#{user.id}") |> response(204)

      assert {:error, :unauthorized} = Auth.verify_token(owner_raw)
      # The non-owner token is untouched: WHERE owner_user_id == user.id is precise.
      assert is_nil(Repo.get(ApiToken, machine.id).revoked_at)
    end

    test "audits the token revocation (token/user_tokens_revoked)" do
      %{token: scim_token, ws: ws} = org_with_ws("pat-audit")
      provision(scim_token, "aud@pat-audit.com") |> json_response(201)
      user = Accounts.get_user_by_email("aud@pat-audit.com")
      owner_pat(user, ws)

      assert scim(scim_token) |> delete("/scim/v2/Users/#{user.id}") |> response(204)

      ev = Repo.one(from e in Event, where: e.action == "user_tokens_revoked")
      assert ev.category == "token"
      assert ev.subject == user.id
      assert ev.metadata["tokens_revoked"] == 1
    end
  end

  describe "organization isolation" do
    test "a token for org B cannot see or deprovision org A's user" do
      %{token: token_a} = org_with_ws("org-a")
      %{token: token_b} = org_with_ws("org-b")
      provision(token_a, "insidea@org-a.com") |> json_response(201)
      user = Accounts.get_user_by_email("insidea@org-a.com")

      # B cannot GET A's user
      assert scim(token_b) |> get("/scim/v2/Users/#{user.id}") |> json_response(404)
      # B cannot DELETE A's user
      assert scim(token_b) |> delete("/scim/v2/Users/#{user.id}") |> json_response(404)
      # A still can
      assert scim(token_a) |> get("/scim/v2/Users/#{user.id}") |> json_response(200)
    end
  end

  describe "auth + listing" do
    test "401 without a valid SCIM token" do
      assert build_conn() |> get("/scim/v2/Users") |> json_response(401)

      assert build_conn()
             |> put_req_header("authorization", "Bearer not-a-real-token")
             |> get("/scim/v2/Users")
             |> json_response(401)
    end

    test "GET /Users?filter=userName eq lists the matching provisioned user" do
      %{token: token} = org_with_ws("listco")
      provision(token, "list@listco.com") |> json_response(201)

      resp =
        scim(token)
        |> get(~s(/scim/v2/Users?filter=userName eq "list@listco.com"))
        |> json_response(200)

      assert resp["totalResults"] == 1
      assert [%{"userName" => "list@listco.com"}] = resp["Resources"]
    end
  end

  # A raw path `:id` reaches `member_of_org?`, binding to Membership.principal_id
  # (and User.id) — both `:binary_id`. Before the guard a non-UUID id raised
  # Ecto.CastError → HTTP 500; now it folds into the not_found branch → SCIM 404.
  describe "malformed id → 404, not 500 (Ecto.CastError #672 class)" do
    test "GET /scim/v2/Users/:id with a non-UUID id → 404 (never a 500)" do
      %{token: token} = org_with_ws("usr-cast")
      assert scim(token) |> get("/scim/v2/Users/not-a-uuid") |> json_response(404)
    end

    test "DELETE /scim/v2/Users/:id with a non-UUID id → 404 (never a 500)" do
      %{token: token} = org_with_ws("usr-cast-del")
      assert scim(token) |> delete("/scim/v2/Users/not-a-uuid") |> json_response(404)
    end

    test "positive control: a valid-shape but unknown UUID → 404 (not 500)" do
      %{token: token} = org_with_ws("usr-unknown")
      assert scim(token) |> get("/scim/v2/Users/#{Ecto.UUID.generate()}") |> json_response(404)
    end

    test "positive control: a valid UUID of a provisioned user → 200" do
      %{token: token} = org_with_ws("usr-ok")
      provision(token, "real@usr-ok.com") |> json_response(201)
      user = Accounts.get_user_by_email("real@usr-ok.com")

      assert scim(token) |> get("/scim/v2/Users/#{user.id}") |> json_response(200)
    end
  end

  # era-w8-scim-conformance — real-IdP (Okta / Azure AD) onboarding breadth.

  describe "ListResponse paging (RFC 7644 §3.4.2.4)" do
    test "honours count as a page limit + emits startIndex/itemsPerPage/totalResults" do
      %{token: token} = org_with_ws("pageco")

      for e <- ~w(a@pageco.com b@pageco.com c@pageco.com),
          do: provision(token, e) |> json_response(201)

      page1 = scim(token) |> get("/scim/v2/Users?count=2") |> json_response(200)
      assert page1["totalResults"] == 3
      assert page1["startIndex"] == 1
      assert page1["itemsPerPage"] == 2
      assert length(page1["Resources"]) == 2
      # ordered by email asc — first page is a@, b@
      assert Enum.map(page1["Resources"], & &1["userName"]) == ["a@pageco.com", "b@pageco.com"]
    end

    test "startIndex offsets into the result set (last page is a partial)" do
      %{token: token} = org_with_ws("page2co")

      for e <- ~w(a@page2co.com b@page2co.com c@page2co.com),
          do: provision(token, e) |> json_response(201)

      last = scim(token) |> get("/scim/v2/Users?startIndex=3&count=2") |> json_response(200)
      assert last["totalResults"] == 3
      assert last["startIndex"] == 3
      assert last["itemsPerPage"] == 1
      assert [%{"userName" => "c@page2co.com"}] = last["Resources"]
    end
  end

  describe "resource meta + ETag concurrency (RFC 7643 §3.1, RFC 7644 §3.14)" do
    test "a provisioned user carries meta.created/lastModified/version + ETag header" do
      %{token: token} = org_with_ws("metaco")
      conn = provision(token, "m@metaco.com")
      body = json_response(conn, 201)

      meta = body["meta"]
      assert meta["resourceType"] == "User"
      assert is_binary(meta["created"])
      assert is_binary(meta["lastModified"])
      assert String.starts_with?(meta["version"], "W/\"")
      assert meta["location"] =~ "/scim/v2/Users/#{body["id"]}"
      # the ETag response header mirrors meta.version
      assert [meta["version"]] == get_resp_header(conn, "etag")
    end

    test "a stale If-Match on PUT → 412 (never silently overwrites)" do
      %{token: token} = org_with_ws("ifmatchco")
      provision(token, "w@ifmatchco.com") |> json_response(201)
      user = Accounts.get_user_by_email("w@ifmatchco.com")

      resp =
        scim(token)
        |> put_req_header("if-match", ~s(W/"0"))
        |> put("/scim/v2/Users/#{user.id}", Jason.encode!(%{"userName" => "w@ifmatchco.com"}))
        |> json_response(412)

      assert resp["status"] == "412"
    end

    test "a matching If-Match on PUT proceeds → 200" do
      %{token: token} = org_with_ws("ifmatchok")
      body = provision(token, "ok@ifmatchok.com") |> json_response(201)
      user = Accounts.get_user_by_email("ok@ifmatchok.com")

      assert scim(token)
             |> put_req_header("if-match", body["meta"]["version"])
             |> put(
               "/scim/v2/Users/#{user.id}",
               Jason.encode!(%{"userName" => "ok@ifmatchok.com"})
             )
             |> json_response(200)
    end
  end

  describe "error shapes carry scimType (RFC 7644 §3.12)" do
    test "400 missing userName → scimType invalidValue" do
      %{token: token} = org_with_ws("scimtypeco")
      resp = scim(token) |> post("/scim/v2/Users", Jason.encode!(%{})) |> json_response(400)
      assert resp["scimType"] == "invalidValue"
      assert resp["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
    end
  end

  describe "discovery endpoints (RFC 7644 §4)" do
    test "GET /ServiceProviderConfig advertises patch/filter/etag" do
      %{token: token} = org_with_ws("spcco")
      resp = scim(token) |> get("/scim/v2/ServiceProviderConfig") |> json_response(200)

      assert resp["patch"]["supported"] == true
      assert resp["filter"]["supported"] == true
      assert resp["filter"]["maxResults"] == 200
      assert resp["etag"]["supported"] == true
      assert [%{"type" => "oauthbearertoken"}] = resp["authenticationSchemes"]
    end

    test "GET /ResourceTypes lists User + Group as a ListResponse" do
      %{token: token} = org_with_ws("rtco")
      resp = scim(token) |> get("/scim/v2/ResourceTypes") |> json_response(200)

      assert resp["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:ListResponse"]
      ids = Enum.map(resp["Resources"], & &1["id"]) |> Enum.sort()
      assert ids == ["Group", "User"]
    end

    test "GET /Schemas lists the core User + Group schemas" do
      %{token: token} = org_with_ws("schemaco")
      resp = scim(token) |> get("/scim/v2/Schemas") |> json_response(200)

      ids = Enum.map(resp["Resources"], & &1["id"])
      assert "urn:ietf:params:scim:schemas:core:2.0:User" in ids
      assert "urn:ietf:params:scim:schemas:core:2.0:Group" in ids
    end

    test "deny: discovery is behind the SCIM bearer — 401 without a token" do
      assert build_conn() |> get("/scim/v2/ServiceProviderConfig") |> json_response(401)
    end
  end

  # `deactivating?/1` guards `is_list(ops)` — the CONTAINER — then reads
  # `op["op"]` on each element, which is `Access.get/3` and raises
  # FunctionClauseError on a scalar Operation -> a generic 500. An `is_map(op)`
  # conjunct drops the malformed entry instead.
  describe "scalar Operations are dropped, never a 500 (element-shape class)" do
    test "PATCH with a scalar Operation returns 200 and leaves the user active" do
      %{token: token} = org_with_ws("uscalarop")
      provision(token, "scalar@uscalarop.com") |> json_response(201)
      user = Accounts.get_user_by_email("scalar@uscalarop.com")

      resp =
        scim(token)
        |> patch("/scim/v2/Users/#{user.id}", Jason.encode!(%{"Operations" => ["x"]}))
        |> json_response(200)

      assert resp["active"] == true
    end
  end

  # ── the cross-org blast radius (pds-bl-deprovision-blast-radius-crosses-orgs) ──
  #
  # One user provisioned into TWO organizations; org A's IdP deprovisions them.
  # Reachability was always org-fenced — the EFFECTS were not. The ruling (see
  # the deprovision_user/3 @doc): sessions die globally BY DESIGN (a
  # UserSession is an identity bearer no org kill can partially revoke,
  # fail-closed); owner PATs are org-scoped on SOFT deprovision (org B's
  # workspace-bound PATs survive; NULL-workspace tokens die, fail-closed) and
  # global on HARD (the FK nilify would orphan any survivor). Every assertion
  # below is a DIRECT Repo/verify read, never a second endpoint.
  describe "cross-org deprovision blast radius (the differential)" do
    alias Barkpark.Accounts.UserSession

    defp two_org_user(tag) do
      a = org_with_ws("#{tag}-a")
      b = org_with_ws("#{tag}-b")
      email = "shared@#{tag}.com"
      provision(a.token, email) |> json_response(201)
      provision(b.token, email) |> json_response(201)
      user = Accounts.get_user_by_email(email)

      {:ok, session} = Accounts.create_user_session_token(user)

      {:ok, {raw_a, pat_a}} =
        Auth.create_personal_access_token("a-device", ["read"],
          role: "member",
          workspace_id: a.ws.id,
          owner_user_id: user.id
        )

      {:ok, {raw_b, pat_b}} =
        Auth.create_personal_access_token("b-device", ["read"],
          role: "member",
          workspace_id: b.ws.id,
          owner_user_id: user.id
        )

      %{
        a: a,
        b: b,
        user: user,
        session: session,
        pat_a: {raw_a, pat_a},
        pat_b: {raw_b, pat_b}
      }
    end

    test "SOFT (PATCH active:false) from org A: sessions die globally (ruled), org B's PAT SURVIVES, org A's dies" do
      %{a: a, b: b, user: user, session: session, pat_a: {raw_a, pat_a}, pat_b: {raw_b, pat_b}} =
        two_org_user("soft-blast")

      body =
        Jason.encode!(%{
          "Operations" => [%{"op" => "replace", "path" => "active", "value" => false}]
        })

      assert scim(a.token) |> patch("/scim/v2/Users/#{user.id}", body) |> json_response(200)

      # Sessions: global kill, ruled intended — DIRECT Repo read: zero live rows.
      assert Repo.aggregate(
               from(st in UserSession,
                 where: st.user_id == ^user.id and is_nil(st.revoked_at)
               ),
               :count,
               :id
             ) == 0

      assert is_nil(Accounts.verify_user_session_token(session))

      # Org A's PAT is dead…
      assert %ApiToken{revoked_at: %DateTime{}} = Repo.get(ApiToken, pat_a.id)
      assert {:error, :unauthorized} = Auth.verify_token(raw_a)

      # …org B's workspace-bound PAT SURVIVES org A's deprovision.
      assert %ApiToken{revoked_at: nil} = Repo.get(ApiToken, pat_b.id)
      assert {:ok, %ApiToken{}} = Auth.verify_token(raw_b)

      # And org B's membership is untouched (the fence half, direct read).
      assert Repo.exists?(
               from m in Membership,
                 where:
                   m.principal_type == "user" and m.principal_id == ^user.id and
                     m.workspace_id == ^b.ws.id
             )
    end

    test "HARD (DELETE) from org A: everything dies — the FK nilify would orphan any survivor" do
      %{a: a, user: user, pat_a: {raw_a, _}, pat_b: {raw_b, pat_b}} = two_org_user("hard-blast")

      assert scim(a.token) |> delete("/scim/v2/Users/#{user.id}") |> response(204)

      # Global on hard, ruled: org B's PAT is revoked too (never orphaned live).
      assert %ApiToken{revoked_at: %DateTime{}} = Repo.get(ApiToken, pat_b.id)
      assert {:error, :unauthorized} = Auth.verify_token(raw_a)
      assert {:error, :unauthorized} = Auth.verify_token(raw_b)
    end
  end
end
