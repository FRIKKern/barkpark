defmodule BarkparkWeb.WorkspacelessPatFlatRouteTest do
  @moduledoc """
  task-e816e87770cd69ce: a PAT self-minted by a user who belongs to NO workspace
  (owner-bound, `workspace_id: nil`, `["read"]` — `AuthController` resolves
  `{nil, nil}`) used to read the Default workspace through every FLAT route,
  because `DeriveWorkspaceFromToken` left it untouched and `AssignDefaultScope`
  stamped Default. `POST /v1/auth/register` is open signup, so anyone could.
  access_token_identity_test case 10 pinned only the SCOPED refusal.

  Now the flat routes refuse it (403, not a member). The CONTROLS pin who must
  keep working: a Default member's PAT (flat and scoped), a grantee whose read
  grant covers Default, a legacy owner-less global token, an owner-less
  public-read site token, and anonymous public reads.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Barkpark.AccessFixtures

  alias Barkpark.{Accounts, Auth, Content, Repo}
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery-staple-9"

  setup do
    {default_ws, default_proj} = ensure_default_scope!()
    ds = "wspat-#{System.unique_integer([:positive])}"

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      ds
    )

    {:ok, _} =
      create_document_in!(
        default_ws,
        default_proj,
        "post",
        %{"_id" => "p1", "title" => "PUBLISHED-ONE"},
        ds
      )

    {:ok, _} =
      Content.publish_document("p1", "post", ds,
        workspace_id: default_ws.id,
        project_id: default_proj.id
      )

    {:ok, _} =
      create_document_in!(
        default_ws,
        default_proj,
        "post",
        %{"_id" => "d1", "title" => "DRAFT-SECRET"},
        ds
      )

    %{default_ws: default_ws, default_proj: default_proj, ds: ds}
  end

  defp user! do
    email = "wspat-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  # The real door: a session-authenticated POST /v1/auth/tokens.
  defp self_mint(user) do
    {:ok, session} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "t")

    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> session)
      |> put_req_header("content-type", "application/json")
      |> post("/v1/auth/tokens", %{"name" => "cli"})

    assert %{"token" => raw} = json_response(resp, 201)
    raw
  end

  defp get_as(raw, path) do
    conn = scoped_conn()
    conn = if raw, do: put_req_header(conn, "authorization", "Bearer " <> raw), else: conn
    get(conn, path)
  end

  defp owned_token!(user) do
    raw = "own-" <> Ecto.UUID.generate()

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "owned",
        dataset: "test",
        permissions: ["read"],
        owner_user_id: user.id
      })
      |> Repo.insert()

    raw
  end

  describe "a workspace-less PAT of a user with no membership" do
    setup do
      user = user!()
      raw = self_mint(user)
      {:ok, minted} = Auth.verify_token(raw)
      assert is_nil(minted.workspace_id), "precondition: the PAT is workspace-less"
      %{raw: raw}
    end

    test "is refused on the flat query route, drafts perspective included", %{raw: raw, ds: ds} do
      resp = get_as(raw, "/v1/data/query/#{ds}/post?perspective=drafts")

      assert resp.status == 403,
             "a signup-minted PAT read the Default workspace (status #{resp.status})"

      refute resp.resp_body =~ "DRAFT-SECRET"
    end

    test "is refused on the flat export route", %{raw: raw, ds: ds} do
      resp = get_as(raw, "/v1/data/export/#{ds}")
      assert resp.status == 403
      refute resp.resp_body =~ "DRAFT-SECRET"
    end

    test "is refused on the flat task ledger", %{raw: raw} do
      assert get_as(raw, "/v1/tasks").status == 403
    end

    # The /api/workspaces scope is exempt (route private
    # `barkpark_workspaceless_token_allowed`): it does its own membership reasoning
    # and never reads Default. Creating a workspace needs WRITE, which a signup
    # PAT (["read"]) does not hold on main either, so this uses the same
    # owned, workspace-less, read+write shape workspace_controller_test pins.
    test "CONTROL: an owned workspace-less token can still create its FIRST workspace" do
      user = user!()
      raw = "own-rw-" <> Ecto.UUID.generate()

      {:ok, _} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "owned-rw",
          dataset: "test",
          permissions: ["read", "write"],
          owner_user_id: user.id
        })
        |> Repo.insert()

      slug = "wspat-first-#{System.unique_integer([:positive])}"

      resp =
        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> put_req_header("content-type", "application/json")
        |> post("/api/workspaces", %{"name" => "First", "slug" => slug})

      assert resp.status == 201, "status #{resp.status}: #{resp.resp_body}"
    end
  end

  describe "CONTROLS: who keeps reading" do
    test "a Default member's PAT reads flat and scoped", ctx do
      user = user!()
      {:ok, _} = TenancyAuth.create_membership(ctx.default_ws.id, user.id, "member", "user")
      raw = self_mint(user)

      assert get_as(raw, "/v1/data/query/#{ctx.ds}/post").status == 200

      scoped = "/w/#{ctx.default_ws.slug}/p/#{ctx.default_proj.slug}/v1/data/query/#{ctx.ds}/post"
      assert get_as(raw, scoped).status == 200
    end

    test "a grantee whose read grant covers Default still reads the flat route", ctx do
      user = user!()
      raw = owned_token!(user)
      bind_grant!(ctx.default_ws, user, %{dataset: ctx.ds, type: "post"})

      resp = get_as(raw, "/v1/data/query/#{ctx.ds}/post")
      assert resp.status == 200
      assert resp.resp_body =~ "PUBLISHED-ONE"
    end

    test "a legacy owner-less global token keeps the Default fallback", %{ds: ds} do
      raw = "legacy-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "legacy", ds, ["read"])

      resp = get_as(raw, "/v1/data/query/#{ds}/post?perspective=drafts")
      assert resp.status == 200
      assert resp.resp_body =~ "DRAFT-SECRET"
    end

    test "an owner-less public-read site token reads published content", %{ds: ds} do
      raw = "site-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "site", ds, ["public-read"])

      resp = get_as(raw, "/v1/data/query/#{ds}/post")
      assert resp.status == 200
      assert resp.resp_body =~ "PUBLISHED-ONE"
    end

    test "anonymous public reads are unaffected", %{ds: ds} do
      resp = get_as(nil, "/v1/data/query/#{ds}/post")
      assert resp.status == 200
      assert resp.resp_body =~ "PUBLISHED-ONE"
      refute resp.resp_body =~ "DRAFT-SECRET"
    end
  end
end
