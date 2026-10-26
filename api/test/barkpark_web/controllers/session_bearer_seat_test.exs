defmodule BarkparkWeb.SessionBearerSeatTest do
  @moduledoc """
  task-a89ef18ee88ba6a0 — three follow-ups to #22764, from barkpark-studio's
  live probe of a MEMBER seat on guerrilla. Every token here comes from the
  REAL `POST /v1/auth/login`, never a hand-minted one.

    1. `GET /v1/auth/token` with a login-session bearer answered 401, so a
       client reading permissions there treated a live session as dead. It now
       describes the session: `kind: "session"` and the user's seats.
    2. A session-bearer mutate with NO cookie answered 403 `csrf_required`.
       CSRF guards the COOKIE only; a bearer carries no ambient credential.
    3. The model: a member seat WRITES content (LiveView Studio's `:member`
       grade gets no read-only gate), so the session writes and its seat says
       `can.write: true`. A member's self-minted PAT is capped at `[read]`
       by `Auth.max_pat_permissions_for_role/1` — a MINTING policy, so that
       PAT cannot write.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Access, Accounts, Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct horse battery staple"
  @dataset "production"

  setup do
    ws = create_workspace!("a89-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    admin_raw = "a89-admin-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Auth.create_token(admin_raw, "a89-admin", @dataset, ["read", "write", "admin"])

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

    email = "member-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)

    %{ws: ws, project: project, admin: admin, admin_raw: admin_raw, email: email, user: user}
  end

  defp json_conn(bearer) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  defp login!(email) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp member!(ctx) do
    token = login!(ctx.email)

    json_conn(ctx.admin_raw)
    |> post(
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/members",
      Jason.encode!(%{email: ctx.email, role: "member"})
    )
    |> json_response(202)

    [inv] =
      json_response(json_conn(token) |> get("/v1/auth/invitations"), 200)["invitations"]

    json_conn(token)
    |> post("/v1/auth/invitations/#{inv["id"]}/accept", "{}")
    |> json_response(201)

    token
  end

  defp mutate_path(ctx), do: "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/mutate/#{@dataset}"

  defp create_body(id),
    do: Jason.encode!(%{mutations: [%{create: %{_id: id, _type: "post", title: "hi"}}]})

  defp schemas_path(ctx),
    do: "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/schemas/#{@dataset}"

  describe "scoped schema reads use the same member session as document reads" do
    test "a seated login bearer reads the index and schema, but cannot manage schemas", ctx do
      token = member!(ctx)
      path = schemas_path(ctx)

      assert json_response(json_conn(token) |> get(path), 200)["schemas"]
             |> Enum.any?(&(&1["name"] == "post"))

      assert json_response(json_conn(token) |> get(path <> "/post"), 200)["schema"]["name"] ==
               "post"

      assert (json_conn(token)
              |> post(path, Jason.encode!(%{name: "forbidden", fields: []}))).status in [401, 403]

      assert (json_conn(token) |> delete(path <> "/post")).status in [401, 403]

      structure = "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/structure/#{@dataset}"
      assert (json_conn(token) |> get(structure)).status in [401, 403]
    end

    test "an existing API token still reads the schema index and one schema", ctx do
      path = schemas_path(ctx)

      assert json_response(json_conn(ctx.admin_raw) |> get(path), 200)["schemas"]
             |> Enum.any?(&(&1["name"] == "post"))

      assert json_response(json_conn(ctx.admin_raw) |> get(path <> "/post"), 200)["schema"][
               "name"
             ] ==
               "post"
    end

    test "a type-limited grant without a workspace seat cannot read any schema", ctx do
      {:ok, %{token: raw}} =
        Access.mint(ctx.admin, %{
          grantee_email: ctx.email,
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id,
          dataset: @dataset,
          type: "granted-type",
          capabilities: ["read"]
        })

      assert {:ok, _} = Access.claim(raw, ctx.user)
      refute TenancyAuth.member?(ctx.user, ctx.ws.id)
      token = login!(ctx.email)

      # Introspection still accepts a live login session without a workspace seat.
      assert json_response(json_conn(token) |> get("/v1/auth/token"), 200)["kind"] == "session"

      statuses =
        for path <- [schemas_path(ctx), schemas_path(ctx) <> "/post"] do
          (json_conn(token) |> get(path)).status
        end

      assert statuses == [403, 403]
    end

    test "missing, revoked and expired sessions cannot read schemas", ctx do
      path = schemas_path(ctx)
      assert (scoped_conn() |> get(path)).status in [401, 403]
      token = member!(ctx)
      assert (json_conn(token) |> get(path)).status == 200

      cookie_only =
        scoped_conn()
        |> Plug.Test.init_test_session(%{"user_session" => token})
        |> get(path)

      assert cookie_only.status in [401, 403]
      json_conn(token) |> delete("/v1/auth/logout") |> json_response(200)
      assert (json_conn(token) |> get(path)).status == 401

      expired = login!(ctx.email)
      {_user, session} = Accounts.verify_user_session(expired)

      session
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      |> Barkpark.Repo.update!()

      assert (json_conn(expired) |> get(path)).status == 401
    end

    test "a valid session cannot read another workspace or keep a removed seat", ctx do
      token = member!(ctx)
      other = create_workspace!("schema-other-#{System.unique_integer([:positive])}")
      project = create_project!(other)
      path = "/w/#{other.slug}/p/#{project.slug}/v1/schemas/#{@dataset}"
      assert (json_conn(token) |> get(path)).status == 403

      ctx.user |> TenancyAuth.membership(ctx.ws.id) |> Barkpark.Repo.delete!()
      assert (json_conn(token) |> get(schemas_path(ctx))).status == 403
    end
  end

  describe "GET /v1/auth/token with a login-session bearer" do
    test "answers 200 describing the session and the member's seat", ctx do
      token = member!(ctx)

      resp = json_conn(token) |> get("/v1/auth/token")
      assert resp.status == 200, resp.resp_body
      body = Jason.decode!(resp.resp_body)

      assert body["kind"] == "session"
      assert body["user"]["email"] == ctx.email

      seat = Enum.find(body["seats"], &(&1["workspace"]["slug"] == ctx.ws.slug))
      assert seat, "no seat for #{ctx.ws.slug} in #{inspect(body["seats"])}"
      assert seat["role"] == "member"

      assert seat["can"] == %{
               "read" => true,
               "write" => true,
               "publish" => true,
               "admin" => false
             }
    end

    test "never leaks the session token or its hash", ctx do
      token = member!(ctx)
      resp = json_conn(token) |> get("/v1/auth/token")
      refute resp.resp_body =~ token
      refute resp.resp_body =~ "token_hash"
    end

    test "a revoked session is 401", ctx do
      token = member!(ctx)
      json_conn(token) |> delete("/v1/auth/logout")

      resp = json_conn(token) |> get("/v1/auth/token")
      assert resp.status == 401, resp.resp_body
    end

    test "an API token still describes itself (kind stays the token's own)", ctx do
      resp = json_conn(ctx.admin_raw) |> get("/v1/auth/token")
      assert resp.status == 200, resp.resp_body
      assert Jason.decode!(resp.resp_body)["kind"] == "api"
    end
  end

  describe "CSRF guards the cookie, never a bearer" do
    test "a session-bearer mutate with no cookie and no x-requested-with writes", ctx do
      token = member!(ctx)

      resp = json_conn(token) |> post(mutate_path(ctx), create_body("drafts.a89-bearer"))
      assert resp.status == 200, resp.resp_body
      refute resp.resp_body =~ "csrf_required"
    end

    test "a cookie-authenticated mutate without x-requested-with is still refused", ctx do
      token = member!(ctx)

      resp =
        scoped_conn()
        |> Plug.Test.init_test_session(%{"user_session" => token})
        |> put_req_header("content-type", "application/json")
        |> post(mutate_path(ctx), create_body("drafts.a89-cookie"))

      assert resp.status in [401, 403], resp.resp_body
    end

    test "the same cookie WITH x-requested-with writes", ctx do
      token = member!(ctx)

      resp =
        scoped_conn()
        |> Plug.Test.init_test_session(%{"user_session" => token})
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-requested-with", "XMLHttpRequest")
        |> post(mutate_path(ctx), create_body("drafts.a89-cookie-ok"))

      assert resp.status == 200, resp.resp_body
    end
  end

  describe "the model: a member session writes, a member PAT cannot" do
    test "the member's self-minted PAT is capped at read and its mutate is refused", ctx do
      token = member!(ctx)
      assert Auth.max_pat_permissions_for_role("member") == ["read"]

      mint =
        json_conn(token)
        |> post("/v1/auth/tokens", Jason.encode!(%{name: "a89-pat", current_password: @password}))

      assert mint.status == 201, mint.resp_body
      minted = Jason.decode!(mint.resp_body)
      assert minted["personal_access_token"]["permissions"] == ["read"]

      resp = json_conn(minted["token"]) |> post(mutate_path(ctx), create_body("drafts.a89-pat"))
      assert resp.status == 403, resp.resp_body
    end

    test "the member's session, same seat, writes", ctx do
      token = member!(ctx)
      resp = json_conn(token) |> post(mutate_path(ctx), create_body("drafts.a89-session"))
      assert resp.status == 200, resp.resp_body
    end
  end

  # task-0d5ac677450d4c8c: the seat gate on the direct publish leaves a member
  # session, which may publish, unchanged.
  test "a member session's direct publish still lands", ctx do
    token = member!(ctx)
    id = "a89-direct-#{System.unique_integer([:positive])}"

    body =
      Jason.encode!(%{
        mutations: [%{createOrReplace: %{_id: id, _type: "post", title: "live"}, publish: true}]
      })

    assert json_response(json_conn(token) |> post(mutate_path(ctx), body), 200)

    assert {:ok, %{title: "live"}} =
             Content.get_document(id, "post", @dataset,
               workspace_id: ctx.ws.id,
               project_id: ctx.project.id
             )
  end
end
