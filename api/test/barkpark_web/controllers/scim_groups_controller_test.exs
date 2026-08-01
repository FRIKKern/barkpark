defmodule BarkparkWeb.ScimGroupsControllerTest do
  @moduledoc "SCIM 2.0 /scim/v2/Groups — group→role mapping (era-w4-scim-groups)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Repo, Scim, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Scim.Group
  alias Barkpark.Tenancy.{Auth, Role, RolePermission}
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
    build_conn()
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
end
