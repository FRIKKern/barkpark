defmodule BarkparkWeb.ShareGrantLoginBearerAnonTest do
  @moduledoc """
  task-7cca731b7f38f939 — pins the boundary #22764 (task-ce99fd602a697010)
  drew: `ResolveWorkspace` assigns `:member_user` ONLY on the membership
  admit, so the read gates (`QueryController.authed?/1`, `AnonPerspective`)
  treat a login-session caller as authed only when membership admitted them.

  A user admitted to W by a `:docs` SHARE link, or by a GRANT, presenting the
  token `POST /v1/auth/login` returned as `Authorization: Bearer`, reads W as
  ANONYMOUS: published documents only, and a private type 404s. The member
  control proves the fixture tells the two apart.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Access, Accounts, Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct horse battery staple"
  @dataset "production"

  setup do
    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    ws = create_workspace!("sg-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    admin_raw = "sg-admin-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Auth.create_token(admin_raw, "sg-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin", "api_token")

    for {name, visibility} <- [{"page", "public"}, {"post", "private"}] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => name,
            "title" => name,
            "visibility" => visibility,
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset,
          workspace_id: ws.id,
          project_id: project.id
        )
    end

    ctx = %{ws: ws, project: project, admin_raw: admin_raw}

    mutate!(ctx, [
      %{create: %{_id: "sg-pub", _type: "page", title: "published"}},
      %{publish: %{id: "sg-pub", type: "page"}},
      %{create: %{_id: "drafts.sg-draft", _type: "page", title: "draft only"}},
      %{create: %{_id: "sg-post", _type: "post", title: "private"}},
      %{publish: %{id: "sg-post", type: "post"}}
    ])

    email = "sg-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)

    Map.merge(ctx, %{email: email, user: user, admin: admin})
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp json_conn(bearer) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  defp mutate!(ctx, mutations) do
    resp =
      json_conn(ctx.admin_raw)
      |> post(
        "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/mutate/#{@dataset}",
        Jason.encode!(%{mutations: mutations})
      )

    assert resp.status == 200, resp.resp_body
  end

  defp login!(email) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp query(ctx, bearer, type) do
    json_conn(bearer)
    |> get(
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/query/#{@dataset}/#{type}?perspective=drafts&limit=50"
    )
  end

  defp ids(resp) do
    resp.resp_body
    |> Jason.decode!()
    |> get_in(["result", "documents"])
    |> Enum.map(& &1["_id"])
    |> Enum.sort()
  end

  # The ANONYMOUS shape: the published page only, no draft; the private type 404s.
  defp assert_reads_as_anonymous(ctx, token) do
    pages = query(ctx, token, "page")
    assert pages.status == 200, pages.resp_body
    page_ids = ids(pages)
    assert "sg-pub" in page_ids, "published page missing: #{inspect(page_ids)}"

    refute Enum.any?(page_ids, &String.contains?(&1, "sg-draft")),
           "a draft leaked to a non-member: #{inspect(page_ids)}"

    private = query(ctx, token, "post")
    assert private.status == 404, private.resp_body
  end

  test "CONTROL: a member's login bearer sees the draft and the private type", ctx do
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, ctx.user.id, "member", "user")
    token = login!(ctx.email)

    pages = query(ctx, token, "page")
    assert pages.status == 200, pages.resp_body
    page_ids = ids(pages)
    assert Enum.any?(page_ids, &String.contains?(&1, "sg-draft")), inspect(page_ids)

    assert query(ctx, token, "post").status == 200
  end

  test "a SHARE-link admit with a login bearer reads as anonymous", ctx do
    assert {:ok, _} =
             Barkpark.Sharing.add_share(
               "#{ctx.ws.slug}/#{ctx.project.slug}/#{@dataset}:docs:read"
             )

    assert Barkpark.Sharing.shared?(ctx.ws.slug, ctx.project.slug, @dataset, :docs)
    refute TenancyAuth.member?(ctx.user, ctx.ws.id)

    assert_reads_as_anonymous(ctx, login!(ctx.email))
  end

  test "a GRANT admit with a login bearer reads as anonymous", ctx do
    {:ok, %{token: raw}} =
      Access.mint(ctx.admin, %{
        grantee_email: ctx.email,
        workspace_id: ctx.ws.id,
        capabilities: ["read"]
      })

    assert {:ok, _} = Access.claim(raw, ctx.user)
    refute TenancyAuth.member?(ctx.user, ctx.ws.id)

    assert_reads_as_anonymous(ctx, login!(ctx.email))
  end
end
