defmodule BarkparkWeb.MemberSessionScopedReadsTest do
  @moduledoc """
  task-d950c303ef58303d: personal bearers use the existing workspace seat
  and read boundary on four editor GETs. Every bearer comes from real login.
  """
  use BarkparkWeb.ConnCase, async: false
  import Barkpark.TenancyFixtures
  alias Barkpark.{Accounts, Auth, Content, Repo}
  alias Barkpark.Content.ScheduledPublish
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct horse battery staple"
  @dataset "production"

  setup do
    shares = Application.get_env(:barkpark, :shares)
    shares_env = Application.get_env(:barkpark, :shares_env)

    on_exit(fn ->
      restore_config(:shares, shares)
      restore_config(:shares_env, shares_env)
    end)

    ws = create_workspace!("session-reads-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    raw = "session-reads-admin-#{System.unique_integer([:positive])}"
    {:ok, admin} = Auth.create_token(raw, "read fixture", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin", "api_token")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    email = "session-reads-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)
    {:ok, seat} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    token = login!(email)
    base = "/w/#{ws.slug}/p/#{project.slug}/v1/data"

    created =
      json_conn(token)
      |> post(
        base <> "/mutate/#{@dataset}",
        Jason.encode!(%{
          mutations: [%{create: %{_id: "drafts.private", _type: "post", title: "private draft"}}]
        })
      )

    assert created.status == 200, created.resp_body

    [revision | _] =
      json_conn(raw)
      |> get(base <> "/history/#{@dataset}/post/drafts.private")
      |> json_response(200)
      |> Map.fetch!("revisions")

    schedule =
      ScheduledPublish.create_changeset(%{
        workspace_id: ws.id,
        project_id: project.id,
        dataset: @dataset,
        type: "post",
        doc_id: "private",
        publish_at: DateTime.add(DateTime.utc_now(), 3600),
        principal_type: "user",
        principal_id: user.id,
        acting_user_id: user.id
      })
      |> Repo.insert!()

    %{
      ws: ws,
      project: project,
      admin_raw: raw,
      admin: admin,
      user: user,
      seat: seat,
      token: token,
      base: base,
      revision: revision,
      schedule: schedule
    }
  end

  defp json_conn(token),
    do:
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

  defp login!(email),
    do:
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
      |> json_response(201)
      |> Map.fetch!("token")

  defp paths(c),
    do: [
      c.base <> "/history/#{@dataset}/post/drafts.private",
      c.base <> "/revision/#{@dataset}/#{c.revision["id"]}",
      c.base <> "/schedules/#{@dataset}",
      c.base <> "/doc/#{@dataset}/post/drafts.private/actions"
    ]

  test "member session reads private draft history with server-stamped actor identity", c do
    body = json_conn(c.token) |> get(Enum.at(paths(c), 0)) |> json_response(200)
    assert [%{"actor_id" => uid, "actor_kind" => "user"}] = body["revisions"]
    assert uid == c.user.id
  end

  test "member session reads the private draft revision", c do
    body = json_conn(c.token) |> get(Enum.at(paths(c), 1)) |> json_response(200)
    assert body["revision"]["id"] == c.revision["id"]
    assert body["revision"]["actor_id"] == c.user.id
    assert body["revision"]["actor_kind"] == "user"
  end

  test "member session lists scoped schedules", c do
    body = json_conn(c.token) |> get(Enum.at(paths(c), 2)) |> json_response(200)
    assert [%{"_id" => id}] = body["result"]["schedules"]
    assert id == c.schedule.id
  end

  test "member session reads resolved actions without dispatching them", c do
    body = json_conn(c.token) |> get(Enum.at(paths(c), 3)) |> json_response(200)
    assert is_list(body["actions"])
    assert Enum.any?(body["actions"], &(&1["name"] == "delete-doc"))
  end

  test "both token policies remain identical to their original router pipelines" do
    router = File.read!(Path.expand("../../../lib/barkpark_web/router.ex", __DIR__))

    for {pipeline, policy} <- [{"require_token", :read}, {"scoped_admin", :scoped_admin}] do
      [_, body] =
        Regex.run(
          Regex.compile!("\\n  pipeline :" <> pipeline <> " do\\n(.*?)\\n  end\\n", "s"),
          router
        )

      plugs =
        Regex.scan(~r/^\s*plug\(([A-Za-z0-9_.]+)/m, body, capture: :all_but_first)
        |> Enum.map(fn [name] -> Module.concat([name]) end)

      assert plugs == BarkparkWeb.Plugs.RequireTokenOrMemberSession.token_chain(policy)
    end
  end

  test "missing, revoked and expired sessions are refused on all four reads", c do
    for path <- paths(c),
        do: assert((scoped_conn() |> get(path)).status in [401, 403])

    json_conn(c.token) |> delete("/v1/auth/logout") |> json_response(200)
    assert_refused(c, c.token)
    fresh = login!(c.user.email)

    session =
      Repo.get_by!(Accounts.UserSession, token_hash: Accounts.UserSession.hash_token(fresh))

    session
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60))
    |> Repo.update!()

    assert_refused(c, fresh)
  end

  test "cookie alone and revoked membership never acquire the bearer exception", c do
    for path <- paths(c) do
      resp =
        scoped_conn() |> Plug.Test.init_test_session(%{"user_session" => c.token}) |> get(path)

      assert resp.status in [401, 403], resp.resp_body
    end

    Repo.delete!(c.seat)
    assert_refused(c, c.token)
  end

  test "share-only and grant-only login users do not acquire member access", c do
    Repo.delete!(c.seat)

    {:ok, %{token: grant}} =
      Barkpark.Access.mint(c.admin, %{
        grantee_email: c.user.email,
        workspace_id: c.ws.id,
        capabilities: ["read"]
      })

    assert {:ok, _} = Barkpark.Access.claim(grant, c.user)
    assert_refused(c, c.token)
    {:ok, _} = Barkpark.Sharing.add_share("#{c.ws.slug}/#{c.project.slug}/#{@dataset}:docs:read")
    assert_refused(c, c.token)
  end

  test "read-only personal seat reads but none of these write doors become available", c do
    alias Barkpark.Tenancy.{Role, RolePermission}
    role = Role.changeset(%Role{}, %{name: "read-only", workspace_id: c.ws.id}) |> Repo.insert!()

    RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
    |> Repo.insert!()

    c.seat |> Ecto.Changeset.change(role: "read-only") |> Repo.update!()
    for path <- paths(c), do: assert((json_conn(c.token) |> get(path)).status == 200)

    for path <- [
          Enum.at(paths(c), 1) <> "/restore",
          Enum.at(paths(c), 2),
          Enum.at(paths(c), 3) <> "/delete-doc"
        ] do
      resp = json_conn(c.token) |> post(path, "{}")
      assert resp.status in [401, 403], resp.resp_body
    end
  end

  test "API tokens keep read and scoped-admin policies and public-read remains denied", c do
    for path <- paths(c), do: assert((json_conn(c.admin_raw) |> get(path)).status == 200)

    for permissions <- [["read"], ["public-read"]] do
      raw = "read-policy-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "reader", @dataset, permissions)
      {:ok, _} = TenancyAuth.create_membership(c.ws.id, token.id, "member", "api_token")

      for path <- Enum.take(paths(c), 3) do
        resp = json_conn(raw) |> get(path)
        assert resp.status == if(permissions == ["read"], do: 200, else: 403), resp.resp_body
      end

      assert (json_conn(raw) |> get(Enum.at(paths(c), 3))).status == 403
    end
  end

  test "tenant, project and dataset swaps cannot reach the original revision or schedules", c do
    other_ws = create_workspace!()
    other_proj = create_project!(other_ws)
    foreign = "/w/#{other_ws.slug}/p/#{other_proj.slug}/v1/data"

    for path <- paths(c) do
      resp = json_conn(c.token) |> get(String.replace_prefix(path, c.base, foreign))
      assert resp.status in [401, 403], resp.resp_body
    end

    project = create_project!(c.ws)

    for base <- ["/w/#{c.ws.slug}/p/#{project.slug}/v1/data", c.base] do
      rev =
        base <> "/revision/#{if(base == c.base, do: "other", else: @dataset)}/#{c.revision["id"]}"

      assert (json_conn(c.token) |> get(rev)).status == 404
      schedules = base <> "/schedules/#{if(base == c.base, do: "other", else: @dataset)}"
      body = json_conn(c.token) |> get(schedules) |> json_response(200)
      assert body["result"]["schedules"] == []
    end
  end

  test "owner-scoped history, revision, actions and schedules hide another member's draft", c do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "private",
          "owner_scoped" => true,
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        workspace_id: c.ws.id,
        project_id: c.project.id
      )

    {:ok, doc} =
      Content.get_document("drafts.private", "post", @dataset,
        workspace_id: c.ws.id,
        project_id: c.project.id
      )

    doc |> Ecto.Changeset.change(owner_id: c.user.id) |> Repo.update!()
    other = another_member!(c)
    body = json_conn(other.token) |> get(Enum.at(paths(c), 0)) |> json_response(200)
    assert body["revisions"] == []
    assert (json_conn(other.token) |> get(Enum.at(paths(c), 1))).status == 404
    assert (json_conn(other.token) |> get(Enum.at(paths(c), 3))).status == 404
    body = json_conn(other.token) |> get(Enum.at(paths(c), 2)) |> json_response(200)
    assert body["result"]["schedules"] == []

    for token <- [c.token, c.admin_raw] do
      body = json_conn(token) |> get(Enum.at(paths(c), 2)) |> json_response(200)
      assert [%{"_id" => id}] = body["result"]["schedules"]
      assert id == c.schedule.id
    end

    Repo.delete!(doc)

    assert (json_conn(c.token)
            |> get(Enum.at(paths(c), 2))
            |> json_response(200))["result"]["schedules"] == []
  end

  test "a readable published twin never authorizes another owner's scheduled draft", c do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "private",
          "owner_scoped" => true,
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        workspace_id: c.ws.id,
        project_id: c.project.id
      )

    {:ok, draft} =
      Content.get_document("drafts.private", "post", @dataset,
        workspace_id: c.ws.id,
        project_id: c.project.id
      )

    draft |> Ecto.Changeset.change(owner_id: c.user.id) |> Repo.update!()
    other = another_member!(c)

    scope = [
      workspace_id: c.ws.id,
      project_id: c.project.id,
      caller_context: Barkpark.Content.CallerContext.from_token(c.admin)
    ]

    {:ok, published} = Content.publish_document("private", "post", @dataset, scope)

    {:ok, replacement_draft} =
      Content.create_document(
        "post",
        %{"doc_id" => "private", "title" => "scheduled draft"},
        @dataset,
        scope
      )

    replacement_draft |> Ecto.Changeset.change(owner_id: c.user.id) |> Repo.update!()
    # Admin reassignment is per row; the published twin is not an ACL for its draft.
    published |> Ecto.Changeset.change(owner_id: other.user.id) |> Repo.update!()

    opts = [
      workspace_id: c.ws.id,
      project_id: c.project.id,
      caller_context: Barkpark.Content.CallerContext.from_user(other.user.id)
    ]

    assert {:ok, _} = Content.get_document("private", "post", @dataset, opts)
    assert {:error, :not_found} = Content.get_document("drafts.private", "post", @dataset, opts)
    body = json_conn(other.token) |> get(Enum.at(paths(c), 2)) |> json_response(200)
    assert body["result"]["schedules"] == []
    owner = json_conn(c.token) |> get(Enum.at(paths(c), 2)) |> json_response(200)
    assert [%{"_id" => id}] = owner["result"]["schedules"]
    assert id == c.schedule.id
  end

  test "revision contents keep private, owner-only and readable-by redaction with current actor labels",
       c do
    other = another_member!(c)

    fields = [
      %{"name" => "title", "type" => "string"},
      %{"name" => "secret", "type" => "string", "private" => true},
      %{"name" => "owner", "type" => "string", "visibility" => "owner_only"},
      %{"name" => "granted", "type" => "string", "readable_by" => [other.user.id]}
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "private", "fields" => fields},
        @dataset,
        workspace_id: c.ws.id,
        project_id: c.project.id
      )

    changed =
      json_conn(c.admin_raw)
      |> post(
        c.base <> "/mutate/#{@dataset}",
        Jason.encode!(%{
          mutations: [
            %{
              patch: %{
                id: "drafts.private",
                type: "post",
                set: %{title: "visible", secret: "SECRET", owner: "OWNER", granted: "GRANTED"}
              }
            }
          ]
        })
      )

    assert changed.status == 200, changed.resp_body

    [rev | _] =
      json_conn(c.admin_raw)
      |> get(Enum.at(paths(c), 0))
      |> json_response(200)
      |> Map.fetch!("revisions")

    revision_path = c.base <> "/revision/#{@dataset}/#{rev["id"]}"

    c.user
    |> Ecto.Changeset.change(email: "erased-#{c.user.id}@erased.invalid", display_name: nil)
    |> Repo.update!()

    body = json_conn(other.token) |> get(revision_path) |> json_response(200)
    assert body["revision"]["content"] == %{"granted" => "GRANTED"}
    assert body["revision"]["title"] == "visible"
    original = json_conn(other.token) |> get(Enum.at(paths(c), 1)) |> json_response(200)
    assert original["revision"]["actor_label"] == "erased-#{c.user.id}@erased.invalid"
    refute Jason.encode!(original) =~ c.user.email
    body = json_conn(c.token) |> get(revision_path) |> json_response(200)
    refute Map.has_key?(body["revision"]["content"], "granted")
  end

  test "TOTP login still requires the factor before issuing a usable personal bearer", c do
    secret = Accounts.totp_secret()
    c.user |> Ecto.Changeset.change(totp_secret: secret, totp_enabled: true) |> Repo.update!()
    json_conn(c.token) |> delete("/v1/auth/logout") |> json_response(200)

    refused =
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/auth/login", Jason.encode!(%{email: c.user.email, password: @password}))
      |> json_response(401)

    assert refused["error"]["code"] == "mfa_required"
    refute Map.has_key?(refused, "token")
    code = Barkpark.TotpTestHelper.totp_code_stable!(secret)

    token =
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/auth/login",
        Jason.encode!(%{email: c.user.email, password: @password, totp_code: code})
      )
      |> json_response(201)
      |> Map.fetch!("token")

    for path <- paths(c), do: assert((json_conn(token) |> get(path)).status == 200)
  end

  defp restore_config(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore_config(key, value), do: Application.put_env(:barkpark, key, value)

  defp assert_refused(c, token) do
    for path <- paths(c) do
      resp = json_conn(token) |> get(path)
      assert resp.status in [401, 403], resp.resp_body
    end
  end

  defp another_member!(c) do
    email = "other-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)
    {:ok, _} = TenancyAuth.create_membership(c.ws.id, user.id, "member", "user")
    %{user: user, token: login!(email)}
  end
end
