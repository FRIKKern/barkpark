defmodule BarkparkWeb.ScimGroupsControllerTest do
  @moduledoc "SCIM 2.0 /scim/v2/Groups — group→role mapping (era-w4-scim-groups)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Repo, Scim, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Scim.Group
  alias Barkpark.Tenancy.{Auth, Membership, Organization, Role, RolePermission, Workspace}
  import Ecto.Query

  defp create_group(token, name, role) do
    scim(token)
    |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => name, "role" => role}))
    |> json_response(201)
  end

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

  defp provision(token, email),
    do:
      scim(token)
      |> post("/scim/v2/Users", Jason.encode!(%{"userName" => email}))
      |> json_response(201)

  defp custom_role(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn a ->
      {:ok, _} =
        Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: a}))
    end)

    role
  end

  # PDS-D551 helpers: stored membership rows are the authority a write receipt
  # must be derived from, so the assertions read them rather than a status code.
  @ext "urn:barkpark:params:scim:schemas:extension:2.0:Group"

  defp stored_roles(user_id),
    do:
      Repo.all(
        from(m in Membership,
          where: m.principal_type == "user" and m.principal_id == ^user_id,
          select: m.role
        )
      )

  defp member_values(body), do: Enum.map(body["members"] || [], & &1["value"])

  defp member_op(op, user_id),
    do:
      Jason.encode!(%{
        "Operations" => [%{"op" => op, "path" => "members", "value" => [%{"value" => user_id}]}]
      })

  describe "group → custom role, enforced at authorize/3" do
    test "adding a user to a group grants the mapped role; removing reverts it" do
      %{ws: ws, token: token} = org_with_ws("grp")
      custom_role(ws.id, "editor-no-publish", ["read"])
      provision(token, "u@grp.com")
      user = Accounts.get_user_by_email("u@grp.com")

      # baseline: provisioned as member → can write
      assert Auth.authorize(user, ws.id, :write) == :ok

      # map a group to the read-only custom role
      gid =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{"displayName" => "Editors", "role" => "editor-no-publish"})
        )
        |> json_response(201)
        |> Map.fetch!("id")

      # add to group → role becomes editor-no-publish → write is now forbidden
      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", user.id))
      |> json_response(200)

      assert Auth.authorize(user, ws.id, :read) == :ok
      assert Auth.authorize(user, ws.id, :write) == {:error, :forbidden}

      # remove from group → reverts to member → write allowed again
      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("remove", user.id))
      |> json_response(200)

      assert Auth.authorize(user, ws.id, :write) == :ok
    end

    test "membership changes are audited" do
      %{ws: ws, token: token} = org_with_ws("grpaudit")
      custom_role(ws.id, "reviewer", ["read"])
      provision(token, "a@grpaudit.com")
      user = Accounts.get_user_by_email("a@grpaudit.com")

      gid =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{"displayName" => "Reviewers", "role" => "reviewer"})
        )
        |> json_response(201)
        |> Map.fetch!("id")

      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", user.id))
      |> json_response(200)

      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("remove", user.id))
      |> json_response(200)

      assert Repo.exists?(from e in Event, where: e.action == "group_member_added")
      assert Repo.exists?(from e in Event, where: e.action == "group_member_removed")
    end
  end

  describe "group creation validation + isolation" do
    test "400 when the mapped role does not exist" do
      %{token: token} = org_with_ws("grpbad")

      assert scim(token)
             |> post(
               "/scim/v2/Groups",
               Jason.encode!(%{"displayName" => "X", "role" => "no-such-role"})
             )
             |> json_response(400)
    end

    test "a built-in role (admin) is an accepted mapping" do
      %{token: token} = org_with_ws("grpadmin")

      assert scim(token)
             |> post(
               "/scim/v2/Groups",
               Jason.encode!(%{"displayName" => "Admins", "role" => "admin"})
             )
             |> json_response(201)
    end

    test "org isolation: a group in org A is not visible to org B" do
      %{token: token_a} = org_with_ws("g-org-a")
      %{token: token_b} = org_with_ws("g-org-b")

      gid =
        scim(token_a)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "AOnly", "role" => "member"}))
        |> json_response(201)
        |> Map.fetch!("id")

      assert scim(token_b) |> get("/scim/v2/Groups/#{gid}") |> json_response(404)
      assert scim(token_a) |> get("/scim/v2/Groups/#{gid}") |> json_response(200)
    end
  end

  describe "DELETE /scim/v2/Groups/:id — via Barkpark.Scim, tenancy-scoped" do
    test "deletes the group in this org" do
      %{token: token} = org_with_ws("grp-del")

      gid =
        scim(token)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "Gone", "role" => "member"}))
        |> json_response(201)
        |> Map.fetch!("id")

      assert scim(token) |> delete("/scim/v2/Groups/#{gid}") |> response(204)
      assert scim(token) |> get("/scim/v2/Groups/#{gid}") |> json_response(404)
    end

    test "org isolation: org B cannot delete a group in org A" do
      %{org: org_a, token: token_a} = org_with_ws("g-del-a")
      %{org: org_b, token: token_b} = org_with_ws("g-del-b")

      gid =
        scim(token_a)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "AOnly", "role" => "member"}))
        |> json_response(201)
        |> Map.fetch!("id")

      # org B can't see it → 404, and the group survives in org A.
      assert scim(token_b) |> delete("/scim/v2/Groups/#{gid}") |> json_response(404)
      assert scim(token_a) |> get("/scim/v2/Groups/#{gid}") |> json_response(200)

      # The context is tenancy-scoped: a delete on org B's behalf removes
      # nothing, and PDS-D523 makes that outcome legible to the caller — the
      # old `{:ok, 0}` was indistinguishable from a real delete under any
      # `{:ok, _}` match. The stored row is read back to certify it.
      group_a = Scim.get_org_group(org_a, gid)
      assert {:error, :not_found} = Scim.delete_group(org_b, group_a)
      assert Repo.get(Group, gid)
      assert Scim.get_org_group(org_a, gid)
    end

    # The controller's own guard, driven for real. Over HTTP the cross-org id is
    # already stopped by the org-scoped read above, so the ONLY way the delete
    # itself can match zero rows is a row that disappears between that read and
    # the write. Nothing is stubbed: a :telemetry handler on the repo's query
    # event (the request runs synchronously in this process, on this test's
    # sandbox connection) issues a real delete the instant the read completes.
    test "the group vanishes between the read and the delete → 404, never 204" do
      %{token: token} = org_with_ws("g-del-race")

      gid =
        scim(token)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "Racy", "role" => "member"}))
        |> json_response(201)
        |> Map.fetch!("id")

      delete_on_next_group_read(gid)

      assert scim(token) |> delete("/scim/v2/Groups/#{gid}") |> json_response(404)
      refute Repo.get(Group, gid)
    end
  end

  # Attach a one-shot repo-query observer that deletes `gid` the moment a SELECT
  # against scim_groups completes — i.e. immediately after the controller's
  # `get_org_group/2` and before its `Scim.delete_group/2`.
  defp delete_on_next_group_read(gid) do
    ref = make_ref()
    handler_id = {__MODULE__, :vanish, ref}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _config ->
        query = to_string(meta[:query] || "")

        if String.starts_with?(query, "SELECT") and query =~ "scim_groups" and
             Process.get(handler_id) == nil do
          Process.put(handler_id, :fired)
          Repo.delete_all(from g in Group, where: g.id == ^gid)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # A raw path `:id` binds to Group's `:binary_id` PK. Before the guard a
  # non-UUID id raised Ecto.CastError → HTTP 500; now it folds into the not_found
  # branch → SCIM 404. Positive control: a well-formed UUID still resolves.
  describe "malformed id → 404, not 500 (Ecto.CastError #672 class)" do
    test "GET /scim/v2/Groups/:id with a non-UUID id → 404 (never a 500)" do
      %{token: token} = org_with_ws("grp-cast")
      assert scim(token) |> get("/scim/v2/Groups/not-a-uuid") |> json_response(404)
    end

    test "PATCH /scim/v2/Groups/:id with a non-UUID id → 404 (never a 500)" do
      %{token: token} = org_with_ws("grp-cast-patch")

      assert scim(token)
             |> patch("/scim/v2/Groups/%2Fnope", member_op("add", "x"))
             |> json_response(404)
    end

    test "positive control: a valid-shape but unknown UUID → 404 (not 500)" do
      %{token: token} = org_with_ws("grp-unknown")
      assert scim(token) |> get("/scim/v2/Groups/#{Ecto.UUID.generate()}") |> json_response(404)
    end

    test "positive control: a valid UUID of an existing group → 200" do
      %{token: token} = org_with_ws("grp-ok")

      gid =
        scim(token)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "Real", "role" => "member"}))
        |> json_response(201)
        |> Map.fetch!("id")

      assert scim(token) |> get("/scim/v2/Groups/#{gid}") |> json_response(200)
    end
  end

  # era-w8-scim-conformance — real-IdP (Okta / Azure AD) onboarding breadth.

  describe "Groups filter + paging (RFC 7644 §3.4.2.4)" do
    test "filter=displayName eq returns only the matching group" do
      %{token: token} = org_with_ws("gfilter")
      create_group(token, "Admins", "admin")
      create_group(token, "Members", "member")

      resp =
        scim(token)
        |> get(~s(/scim/v2/Groups?filter=displayName eq "Admins"))
        |> json_response(200)

      assert resp["totalResults"] == 1
      assert [%{"displayName" => "Admins"}] = resp["Resources"]
      assert resp["startIndex"] == 1
      assert resp["itemsPerPage"] == 1
    end

    test "count/startIndex page the group list; totalResults is the full count" do
      %{token: token} = org_with_ws("gpage")
      create_group(token, "Alphas", "admin")
      create_group(token, "Betas", "member")
      create_group(token, "Gammas", "owner")

      page = scim(token) |> get("/scim/v2/Groups?count=2") |> json_response(200)
      assert page["totalResults"] == 3
      assert page["itemsPerPage"] == 2
      # ordered by displayName asc
      assert Enum.map(page["Resources"], & &1["displayName"]) == ["Alphas", "Betas"]
    end
  end

  describe "PUT /scim/v2/Groups/:id — full replace (displayName + members)" do
    test "renames the group and reconciles membership to exactly the new set" do
      %{ws: ws, token: token} = org_with_ws("gput")
      custom_role(ws.id, "reviewer", ["read"])
      provision(token, "u1@gput.com")
      provision(token, "u2@gput.com")
      u1 = Accounts.get_user_by_email("u1@gput.com")
      u2 = Accounts.get_user_by_email("u2@gput.com")

      gid = create_group(token, "Reviewers", "reviewer") |> Map.fetch!("id")

      # PUT members [u1] → u1 gains reviewer (read-only), u2 untouched (member)
      body1 =
        scim(token)
        |> put(
          "/scim/v2/Groups/#{gid}",
          Jason.encode!(%{"displayName" => "Reviewers", "members" => [%{"value" => u1.id}]})
        )
        |> json_response(200)

      assert Auth.authorize(u1, ws.id, :write) == {:error, :forbidden}
      assert Auth.authorize(u2, ws.id, :write) == :ok

      # PUT members [u2] → u1 reverts to member, u2 becomes reviewer; group renamed
      resp =
        scim(token)
        |> put(
          "/scim/v2/Groups/#{gid}",
          Jason.encode!(%{"displayName" => "Reviewers 2", "members" => [%{"value" => u2.id}]})
        )
        |> json_response(200)

      assert resp["displayName"] == "Reviewers 2"
      assert Auth.authorize(u1, ws.id, :write) == :ok
      assert Auth.authorize(u2, ws.id, :write) == {:error, :forbidden}
      # renamed group is fetchable under the new name filter
      assert body1["displayName"] == "Reviewers"
    end

    test "cross-org isolation: org B cannot PUT-replace a group in org A → 404" do
      %{token: token_a} = org_with_ws("gput-a")
      %{token: token_b} = org_with_ws("gput-b")
      gid = create_group(token_a, "AOnly", "member") |> Map.fetch!("id")

      assert scim(token_b)
             |> put("/scim/v2/Groups/#{gid}", Jason.encode!(%{"displayName" => "Hijacked"}))
             |> json_response(404)

      # untouched in org A
      assert %{"displayName" => "AOnly"} =
               scim(token_a) |> get("/scim/v2/Groups/#{gid}") |> json_response(200)
    end
  end

  describe "resource meta + ETag concurrency (RFC 7643 §3.1, RFC 7644 §3.14)" do
    test "a group carries meta.created/lastModified/version + ETag header" do
      %{token: token} = org_with_ws("gmeta")

      conn =
        scim(token)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "M", "role" => "member"}))

      body = json_response(conn, 201)
      meta = body["meta"]
      assert meta["resourceType"] == "Group"
      assert is_binary(meta["created"])
      assert String.starts_with?(meta["version"], "W/\"")
      assert [meta["version"]] == get_resp_header(conn, "etag")
    end

    test "a stale If-Match on PUT → 412 (optimistic concurrency guard)" do
      %{token: token} = org_with_ws("gifmatch")
      gid = create_group(token, "Guarded", "member") |> Map.fetch!("id")

      resp =
        scim(token)
        |> put_req_header("if-match", ~s(W/"0"))
        |> put("/scim/v2/Groups/#{gid}", Jason.encode!(%{"displayName" => "Guarded 2"}))
        |> json_response(412)

      assert resp["status"] == "412"
    end
  end

  # IdP-supplied MEMBER ids (POST `members[].value` / PATCH Operations value)
  # bind into `set_member_role/3`'s `:binary_id` compare. Before the guard a
  # non-UUID member value raised `Ecto.Query.CastError` (phoenix_ecto maps it to
  # a generic 400 — a SCIM-conformance gap vs the guarded `replace_group_members`
  # path, which folds the same input to a clean no-op); now every member write
  # routes through `Repo.uuid_or_nil` and folds to a no-op. ConnCase re-raises
  # dispatch exceptions (the 400 is unobservable here), so the mutation-proof is
  # the RAISE→NO-RAISE transition: these requests complete with a clean 201/200.
  describe "non-UUID member ids fold to a no-op, never raise (CastError member-write class)" do
    test "POST /scim/v2/Groups with a non-UUID member value → 201, member ignored" do
      %{token: token} = org_with_ws("gmember-cast")

      body =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{
            "displayName" => "CastGuard",
            "role" => "member",
            "members" => [%{"value" => "not-a-uuid"}]
          })
        )
        |> json_response(201)

      assert body["displayName"] == "CastGuard"
      # the garbage id granted nothing and audited nothing
      refute Repo.exists?(from e in Event, where: e.subject == "not-a-uuid")
    end

    test "PATCH add/remove with a non-UUID member → 200 no-op; a valid member still resolves" do
      %{ws: ws, token: token} = org_with_ws("gmember-castp")
      custom_role(ws.id, "reviewer", ["read"])
      provision(token, "ok@gmember-castp.com")
      user = Accounts.get_user_by_email("ok@gmember-castp.com")
      gid = create_group(token, "Reviewers", "reviewer") |> Map.fetch!("id")

      # add with a garbage member id → clean 200, nothing granted
      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", "not-a-uuid"))
      |> json_response(200)

      assert Auth.authorize(user, ws.id, :write) == :ok

      # remove with a garbage member id → clean 200, still a no-op
      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("remove", "also-not-a-uuid"))
      |> json_response(200)

      # positive control: a valid member UUID still resolves through the same path
      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", user.id))
      |> json_response(200)

      assert Auth.authorize(user, ws.id, :write) == {:error, :forbidden}
    end
  end

  # PDS-D551. Three write sites discarded their member-grant results and then
  # answered success: create/2 (via apply_members/3), update/2's Operations
  # comprehension (which then rendered the PRE-mutation group), and replace/2.
  # The callee could not fail — add/remove returned {:ok, 0} for "granted
  # nobody" — so the callee was widened to {:error, :no_membership} first and
  # the receipt now carries `members` READ BACK FROM STORED ROWS. Every
  # assertion below reads stored membership rows or the read-back receipt; a
  # status code alone cannot distinguish a grant that took from one that
  # matched nobody, which is exactly the lie under test.
  #
  # Reachability (re-derived at origin/main f85188bdf): router.ex:1493 opens
  # scope "/scim/v2" and :1494 is pipe_through(:scim); pipeline :scim
  # (router.ex:86-91) is accepts json / ApiSecurityHeaders / RateLimit /
  # RequireScimToken and nothing else, and RequireScimToken.call/2 resolves a
  # Bearer to an Organization only — no user, no role, no membership. The path
  # is ADMIN-MINTED (Scim.mint_token/2), NON-ADMIN-AUTHORIZED (no admin plug at
  # request time) and THIRD-PARTY-DRIVEN (the IdP holds the token).
  describe "member grants answer over the write, not over the request (PDS-D551)" do
    # POST /scim/v2/Groups (router.ex:1508)
    test "POST: a member id that matches nobody does not answer like a real grant" do
      %{ws: ws, token: token} = org_with_ws("grcpt")
      custom_role(ws.id, "auditor", ["read"])
      # a DISTINCT mapped role: group membership is "holds the group's role", so
      # two groups sharing a role legitimately share members — the phantom group
      # must map elsewhere for the comparison to be about the grant.
      custom_role(ws.id, "phantom-auditor", ["read"])
      provision(token, "real@grcpt.com")
      real = Accounts.get_user_by_email("real@grcpt.com")
      ghost = Ecto.UUID.generate()

      granted =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{
            "displayName" => "Auditors",
            "role" => "auditor",
            "members" => [%{"value" => real.id}]
          })
        )
        |> json_response(201)

      phantom =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{
            "displayName" => "Phantoms",
            "role" => "phantom-auditor",
            "members" => [%{"value" => ghost}]
          })
        )
        |> json_response(201)

      # the two 201s are NOT the same answer
      assert member_values(granted) == [real.id]
      assert member_values(phantom) == []
      assert granted[@ext] == nil
      assert phantom[@ext]["unmatchedMembers"] == [ghost]

      # stored rows, not the receipt, are the authority the receipt was derived from
      assert stored_roles(real.id) == ["auditor"]
    end

    # PATCH /scim/v2/Groups/:id (router.ex:1512)
    test "PATCH: the body reflects POST-mutation membership read back from stored rows" do
      %{ws: ws, token: token} = org_with_ws("grpatch")
      custom_role(ws.id, "reviewer", ["read"])
      provision(token, "p@grpatch.com")
      user = Accounts.get_user_by_email("p@grpatch.com")
      gid = create_group(token, "Reviewers", "reviewer") |> Map.fetch!("id")

      assert stored_roles(user.id) == ["member"]

      added =
        scim(token)
        |> patch("/scim/v2/Groups/#{gid}", member_op("add", user.id))
        |> json_response(200)

      # the PRE-mutation group carried no members; this body does
      assert member_values(added) == [user.id]
      assert stored_roles(user.id) == ["reviewer"]

      removed =
        scim(token)
        |> patch("/scim/v2/Groups/#{gid}", member_op("remove", user.id))
        |> json_response(200)

      assert member_values(removed) == []
      assert stored_roles(user.id) == ["member"]
    end

    test "PATCH: an op that matched nobody is reported, not folded into a bare 200" do
      %{ws: ws, token: token} = org_with_ws("grpmiss")
      custom_role(ws.id, "triage", ["read"])
      gid = create_group(token, "Triage", "triage") |> Map.fetch!("id")
      ghost = Ecto.UUID.generate()

      body =
        scim(token)
        |> patch("/scim/v2/Groups/#{gid}", member_op("add", ghost))
        |> json_response(200)

      assert member_values(body) == []
      assert body[@ext]["unmatchedMembers"] == [ghost]
      assert stored_roles(ghost) == []
    end

    # PUT /scim/v2/Groups/:id (router.ex:1511)
    test "PUT: full-replace answers over the reconciliation it actually performed" do
      %{ws: ws, token: token} = org_with_ws("grput")
      custom_role(ws.id, "release", ["read"])
      provision(token, "a@grput.com")
      provision(token, "b@grput.com")
      a = Accounts.get_user_by_email("a@grput.com")
      b = Accounts.get_user_by_email("b@grput.com")
      gid = create_group(token, "Releasers", "release") |> Map.fetch!("id")
      ghost = Ecto.UUID.generate()

      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", a.id))
      |> json_response(200)

      assert stored_roles(a.id) == ["release"]

      # replace {a} with {b, ghost}: b is granted, a is reverted, ghost matched nobody
      body =
        scim(token)
        |> put(
          "/scim/v2/Groups/#{gid}",
          Jason.encode!(%{
            "displayName" => "Releasers",
            "members" => [%{"value" => b.id}, %{"value" => ghost}]
          })
        )
        |> json_response(200)

      assert member_values(body) == [b.id]
      assert body[@ext]["unmatchedMembers"] == [ghost]
      assert stored_roles(a.id) == ["member"]
      assert stored_roles(b.id) == ["release"]
    end

    # HIGH-FLIP-RISK: tenancy. The token is org-scoped, so a member id from
    # ANOTHER org matches zero rows in this org's workspaces — the write must
    # refuse it rather than answer 201 over a grant that never happened, and
    # org B's stored rows must be untouched.
    test "cross-org: a token for org A cannot grant membership to a user in org B" do
      %{ws: ws_a, token: token_a} = org_with_ws("xorga")
      %{token: token_b} = org_with_ws("xorgb")
      custom_role(ws_a.id, "xrole", ["read"])
      provision(token_b, "b@xorgb.com")
      user_b = Accounts.get_user_by_email("b@xorgb.com")

      assert stored_roles(user_b.id) == ["member"]

      body =
        scim(token_a)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{
            "displayName" => "Cross",
            "role" => "xrole",
            "members" => [%{"value" => user_b.id}]
          })
        )
        |> json_response(201)

      # refused in the receipt …
      assert member_values(body) == []
      assert body[@ext]["unmatchedMembers"] == [user_b.id]

      # … and refused in the stored rows: org B's membership never moved
      assert stored_roles(user_b.id) == ["member"]

      # and nothing was audited as a grant that did not happen
      refute Repo.exists?(
               from(e in Event,
                 where: e.subject == ^user_b.id and e.action == "group_member_added"
               )
             )
    end

    test "PATCH: a cross-org remove cannot revoke a role in another org" do
      %{ws: ws_a, token: token_a} = org_with_ws("xorgrm-a")
      %{ws: ws_b, token: token_b} = org_with_ws("xorgrm-b")
      custom_role(ws_a.id, "arole", ["read"])
      custom_role(ws_b.id, "brole", ["read"])
      provision(token_b, "b@xorgrm.com")
      user_b = Accounts.get_user_by_email("b@xorgrm.com")

      gid_b = create_group(token_b, "B", "brole") |> Map.fetch!("id")

      scim(token_b)
      |> patch("/scim/v2/Groups/#{gid_b}", member_op("add", user_b.id))
      |> json_response(200)

      assert stored_roles(user_b.id) == ["brole"]

      gid_a = create_group(token_a, "A", "arole") |> Map.fetch!("id")

      body =
        scim(token_a)
        |> patch("/scim/v2/Groups/#{gid_a}", member_op("remove", user_b.id))
        |> json_response(200)

      assert body[@ext]["unmatchedMembers"] == [user_b.id]
      assert stored_roles(user_b.id) == ["brole"]
    end
  end

  # PDS-D568: the LIST used to omit `members` entirely, citing "RFC 7644 §3.4.2
  # attribute exclusion" — a licence the code does not have (`excludedAttributes`
  # appears nowhere in api/, and /scim/v2/Schemas advertises `members` with
  # "returned" => "default"). Nothing pinned the list shape in either direction:
  # the only two Resources assertions were a partial map pattern and a
  # displayName projection, both of which survive an added key.
  #
  # These assertions read STORED MEMBERSHIP ROWS, not the receipt of a grant the
  # test just made, and the cost claim is measured by TELEMETRY, not by reading.
  describe "GET /scim/v2/Groups renders members from stored rows (PDS-D568)" do
    # Every repo query the REQUEST issues: ConnTest dispatches in the test
    # process, so `self() == test` inside the handler isolates this request's
    # queries from any other test's.
    defp queries_during(fun) do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:barkpark, :repo, :query],
        fn _event, _measurements, meta, _cfg ->
          if self() == test, do: send(test, {ref, meta.query})
        end,
        nil
      )

      try do
        fun.()
      after
        :telemetry.detach({__MODULE__, ref})
      end

      drain_queries(ref, [])
    end

    defp drain_queries(ref, acc) do
      receive do
        {^ref, query} -> drain_queries(ref, [query | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    # THE AUTHORITY IS ORG-KEYED (PDS-W41). It used to take a role alone and
    # query `Membership` with NO org filter, which made it AGREE with an
    # unscoped implementation by construction: deleting the
    # `m.workspace_id in ^ws_ids` fence from `Scim.group_member_ids_by_role/2`
    # left every assertion here green. An oracle that cannot disagree with the
    # thing it checks is not an oracle. The org now scopes the read through
    # `workspaces.organization_id` — the same fence `workspace_ids/1` applies —
    # so a leak across orgs shows up as a difference, not as silence.
    defp stored_holders(%Organization{id: oid}, role) do
      Repo.all(
        from(m in Membership,
          join: w in Workspace,
          on: w.id == m.workspace_id,
          where: m.principal_type == "user" and m.role == ^role and w.organization_id == ^oid,
          select: m.principal_id,
          distinct: true
        )
      )
      |> Enum.sort()
    end

    test "every Resource carries the role's STORED holders, fanned out across groups sharing a role" do
      %{org: org, ws: ws, token: token} = org_with_ws("glistmem")
      custom_role(ws.id, "list-reviewer", ["read"])
      provision(token, "a@glistmem.com")
      provision(token, "b@glistmem.com")
      a = Accounts.get_user_by_email("a@glistmem.com")
      b = Accounts.get_user_by_email("b@glistmem.com")

      # Two groups on ONE role is legitimate (a group IS "holds this role"), so
      # both must answer with that role's holders — the fan-out.
      gid = create_group(token, "Reviewers", "list-reviewer") |> Map.fetch!("id")
      create_group(token, "Reviewers Mirror", "list-reviewer")
      # a third group on a DIFFERENT role must NOT inherit them
      custom_role(ws.id, "list-bystander", ["read"])
      create_group(token, "Zeta Bystanders", "list-bystander")

      for u <- [a, b] do
        scim(token)
        |> patch("/scim/v2/Groups/#{gid}", member_op("add", u.id))
        |> json_response(200)
      end

      # THE AUTHORITY: membership rows read back from the store, not the receipt
      # of the PATCHes above.
      stored = stored_holders(org, "list-reviewer")
      assert stored == Enum.sort([a.id, b.id])
      assert stored_holders(org, "list-bystander") == []

      resources =
        scim(token)
        |> get("/scim/v2/Groups")
        |> json_response(200)
        |> Map.fetch!("Resources")

      by_name =
        Map.new(resources, fn r -> {r["displayName"], Enum.sort(member_values(r))} end)

      assert by_name == %{
               "Reviewers" => stored,
               "Reviewers Mirror" => stored,
               "Zeta Bystanders" => []
             }
    end

    test "membership costs ONE query a page — the same repo-query count for 1 group and for 20" do
      %{ws: ws, token: token} = org_with_ws("glistcost")
      custom_role(ws.id, "cost-role", ["read"])
      provision(token, "c@glistcost.com")
      c = Accounts.get_user_by_email("c@glistcost.com")

      gid = create_group(token, "Group 01", "cost-role") |> Map.fetch!("id")

      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", c.id))
      |> json_response(200)

      one = queries_during(fn -> scim(token) |> get("/scim/v2/Groups") |> json_response(200) end)

      for n <- 2..20 do
        create_group(token, "Group #{String.pad_leading(to_string(n), 2, "0")}", "cost-role")
      end

      twenty =
        queries_during(fn ->
          body = scim(token) |> get("/scim/v2/Groups") |> json_response(200)
          assert body["totalResults"] == 20
          # and the extra 19 groups all answer with the same stored holder
          assert Enum.all?(body["Resources"], &(member_values(&1) == [c.id]))
        end)

      # THE TABLE IS `workspace_memberships`, not `memberships`: a proof that
      # greps the wrong name counts 0 and reads as a pass.
      membership_queries = fn qs -> Enum.count(qs, &(&1 =~ ~s(FROM "workspace_memberships"))) end

      assert membership_queries.(one) == 1,
             "1 group: #{inspect(one)}"

      assert membership_queries.(twenty) == 1,
             "20 groups: #{inspect(twenty)}"

      assert length(one) == length(twenty),
             "page-size dependent cost — 1 group: #{inspect(one)}\n20 groups: #{inspect(twenty)}"
    end

    # HIGH-FLIP-RISK: tenancy (PDS-W41). THE FENCE, NOT THE FEATURE.
    #
    # `Scim.group_member_ids_by_role/2` scopes its membership read with
    # `m.workspace_id in ^ws_ids`. Deleting that clause at origin/main left this
    # file at 30 tests / 0 failures BYTE-IDENTICAL, and the four-file SCIM
    # surface at 60/0 — zero tests moved. Two structural reasons, both defeated
    # here: the authority helper was org-blind (now org-keyed, above), and every
    # existing test mints a UNIQUELY-NAMED role, so the corpus structurally could
    # not contain the cross-org role-name COLLISION the fence exists to stop. A
    # corpus that cannot hold its own sentinel produces silence, and silence
    # reads as success.
    #
    # So: two orgs, each INDEPENDENTLY owning a role of the same name (roles are
    # workspace-keyed, so this is legal and needs no conspiracy), org B's user
    # holding it, org A's group on that name with zero members of its own. Org
    # A's GET must render an EMPTY member list. Against the unfenced tree it
    # renders org B's principal id, and the assertion prints it.
    test "cross-org: a role name owned by BOTH orgs does not leak org B's holders into org A's listing" do
      %{org: org_a, ws: ws_a, token: token_a} = org_with_ws("xlist-a")
      %{org: org_b, ws: ws_b, token: token_b} = org_with_ws("xlist-b")

      # The SAME string, minted independently in each org's own workspace.
      shared = "shared-name"
      custom_role(ws_a.id, shared, ["read"])
      custom_role(ws_b.id, shared, ["read"])

      provision(token_b, "b@xlist.com")
      user_b = Accounts.get_user_by_email("b@xlist.com")

      gid_b = create_group(token_b, "B Holders", shared) |> Map.fetch!("id")

      scim(token_b)
      |> patch("/scim/v2/Groups/#{gid_b}", member_op("add", user_b.id))
      |> json_response(200)

      # THE AUTHORITY, org-keyed: the holder exists in B and in B only.
      assert stored_holders(org_b, shared) == [user_b.id]
      assert stored_holders(org_a, shared) == []

      # Org A's group carries the same role name and NO members of its own.
      gid_a = create_group(token_a, "A Holders", shared) |> Map.fetch!("id")

      resources =
        scim(token_a)
        |> get("/scim/v2/Groups")
        |> json_response(200)
        |> Map.fetch!("Resources")

      leaked =
        resources
        |> Enum.flat_map(&member_values/1)
        |> Enum.uniq()

      assert leaked == [],
             "CROSS-TENANT DISCLOSURE: org A's GET /scim/v2/Groups returned #{inspect(leaked)}; " <>
               "org B's user is #{user_b.id}"

      # THE TWIN FENCE, PINNED IN THE SAME BREATH (added at wave-41 review).
      # The LIST path resolves members through `group_member_ids_by_role/2`; the
      # SINGLE-group GET resolves them through `group_member_ids/2`, a DIFFERENT
      # query carrying its own copy of `m.workspace_id in ^ws_ids`. Measured
      # rather than assumed: deleting the fence from `group_member_ids/2` alone
      # left the Groups + Users files at 58 tests / 0 failures — the singular
      # read was as unpinned as the list read was before this test existed. One
      # extra request closes it, and the assertion prints what leaked.
      singular =
        scim(token_a)
        |> get("/scim/v2/Groups/#{gid_a}")
        |> json_response(200)
        |> member_values()
        |> Enum.uniq()

      assert singular == [],
             "CROSS-TENANT DISCLOSURE on the SINGULAR read: org A's " <>
               "GET /scim/v2/Groups/#{gid_a} returned #{inspect(singular)}; " <>
               "org B's user is #{user_b.id}"
    end

    # COVERAGE, NOT A BOUNDARY DEFECT. `group_member_ids_by_role(%Organization{}, [])`
    # is reached by the MOST ORDINARY request the endpoint serves — the controller
    # maps the page to role names, and an empty page yields `[]` — yet a bare
    # `raise` in that head left all 30 tests green. Removing the head entirely is
    # behaviourally IDENTICAL (the general clause with `role_names = []` returns
    # `%{}` and the same clean 200), so this pins reachability, not a fence.
    test "an org with zero groups lists cleanly — the empty role_names head is actually reached" do
      %{token: token} = org_with_ws("glistempty")

      body =
        scim(token)
        |> get("/scim/v2/Groups")
        |> json_response(200)

      assert body["Resources"] == []
      assert body["totalResults"] == 0
    end
  end

  describe "error shapes carry scimType (RFC 7644 §3.12)" do
    test "unknown role → 400 scimType invalidValue" do
      %{token: token} = org_with_ws("gscimtype")

      resp =
        scim(token)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "X", "role" => "nope"}))
        |> json_response(400)

      assert resp["scimType"] == "invalidValue"
    end

    test "renaming a group onto an existing displayName → 409 scimType uniqueness" do
      %{token: token} = org_with_ws("guniq")
      create_group(token, "Admins", "admin")
      gid = create_group(token, "Members", "member") |> Map.fetch!("id")

      resp =
        scim(token)
        |> put("/scim/v2/Groups/#{gid}", Jason.encode!(%{"displayName" => "Admins"}))
        |> json_response(409)

      assert resp["scimType"] == "uniqueness"
    end
  end

  # A scalar element inside an is_list-guarded param reached `Access.get/3`
  # (`&1["value"]` / `&1["path"]`) and raised FunctionClauseError → a generic 500,
  # not even the SCIM Error shape an IdP can parse. The element shape is now
  # filtered before the Access hop; a malformed entry is DROPPED, matching what
  # the pre-existing is_binary filter already does to a `{"value": 123}` member.
  describe "scalar members / Operations are dropped, never a 500 (element-shape class)" do
    test "POST with string members returns 201 and no members" do
      %{token: token} = org_with_ws("gscalarpost")

      body =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{
            "displayName" => "Admins",
            "role" => "admin",
            "members" => ["u1", "u2"]
          })
        )
        |> json_response(201)

      assert member_values(body) == []
    end

    # THE PRECONDITION, PINNED: an empty displayName is rejected by
    # Scim.create_group BEFORE member_ids/1 ever runs, so a probe with a bare bad
    # body records a clean 400 and would falsely refute the crash above. A valid
    # displayName AND role are load-bearing for reaching the element-shape path.
    test "an empty displayName still returns 400 (validation precedes member_ids/1)" do
      %{token: token} = org_with_ws("gscalarpre")

      assert scim(token)
             |> post(
               "/scim/v2/Groups",
               Jason.encode!(%{"displayName" => "", "role" => "admin", "members" => ["u1"]})
             )
             |> json_response(400)
    end

    test "PUT replace with a numeric member returns 200 and no members" do
      %{token: token} = org_with_ws("gscalarput")
      gid = create_group(token, "Admins", "admin") |> Map.fetch!("id")

      body =
        scim(token)
        |> put(
          "/scim/v2/Groups/#{gid}",
          Jason.encode!(%{"displayName" => "Admins", "members" => [123]})
        )
        |> json_response(200)

      assert member_values(body) == []
    end

    test "PATCH with a scalar Operation returns 200 (member_ops/1 &1[\"path\"])" do
      %{token: token} = org_with_ws("gscalarop")
      gid = create_group(token, "Admins", "admin") |> Map.fetch!("id")

      body =
        scim(token)
        |> patch("/scim/v2/Groups/#{gid}", Jason.encode!(%{"Operations" => ["members"]}))
        |> json_response(200)

      assert member_values(body) == []
    end

    test "PATCH with a scalar inside the op value returns 200 (member_ids/1 &1[\"value\"])" do
      %{token: token} = org_with_ws("gscalarval")
      gid = create_group(token, "Admins", "admin") |> Map.fetch!("id")

      op =
        Jason.encode!(%{
          "Operations" => [%{"op" => "add", "path" => "members", "value" => ["u1"]}]
        })

      body = scim(token) |> patch("/scim/v2/Groups/#{gid}", op) |> json_response(200)
      assert member_values(body) == []
    end
  end
end
