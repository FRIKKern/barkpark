defmodule BarkparkWeb.SessionBearerListsTest do
  @moduledoc """
  task-6224d34a5a8a6017 — the switcher's three LISTs (`GET /api/workspaces`,
  `…/projects`, `…/datasets`) take a login session as the bearer, as the scoped
  data API (#22764) and its streams (#23023) do. They answered it 401, so a
  signed-in studio editor could not list a dataset to switch to. A session
  lists only what its user is seated in. Every session comes from the real
  `POST /v1/auth/login`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.UserSession
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct horse battery staple"

  setup do
    seated = create_workspace!("s622-in-#{System.unique_integer([:positive])}")
    seated_proj = create_project!(seated, "s622-p-#{System.unique_integer([:positive])}")
    {:ok, _} = Barkpark.Tenancy.create_dataset(seated_proj, %{slug: "s622-ds", name: "s622-ds"})
    other = create_workspace!("s622-out-#{System.unique_integer([:positive])}")
    other_proj = create_project!(other, "s622-q-#{System.unique_integer([:positive])}")

    email = "s622-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)
    {:ok, _} = TenancyAuth.create_membership(seated.id, user.id, "member", "user")

    raw = "s622-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "s622-token", "production", ["read"], other.id)

    %{
      seated: seated,
      seated_proj: seated_proj,
      other: other,
      other_proj: other_proj,
      email: email,
      session: login!(email),
      token: raw
    }
  end

  defp login!(email) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp get_as(raw, path),
    do: scoped_conn() |> put_req_header("authorization", "Bearer " <> raw) |> get(path)

  defp slugs(resp, key),
    do: resp |> json_response(200) |> Map.fetch!(key) |> Enum.map(& &1["slug"])

  defp projects(ws), do: "/api/workspaces/#{ws.slug}/projects"
  defp datasets(ws, proj), do: "/api/workspaces/#{ws.slug}/projects/#{proj.slug}/datasets"

  describe "a login-session bearer" do
    test "lists only the workspaces its user is seated in", ctx do
      listed = get_as(ctx.session, "/api/workspaces") |> slugs("workspaces")
      assert ctx.seated.slug in listed
      refute ctx.other.slug in listed
    end

    test "lists the projects and datasets of a seated workspace", ctx do
      assert ctx.seated_proj.slug in slugs(get_as(ctx.session, projects(ctx.seated)), "projects")

      assert "s622-ds" in slugs(
               get_as(ctx.session, datasets(ctx.seated, ctx.seated_proj)),
               "datasets"
             )
    end

    test "is refused 403 on a workspace its user is not seated in", ctx do
      assert get_as(ctx.session, projects(ctx.other)).status == 403
      assert get_as(ctx.session, datasets(ctx.other, ctx.other_proj)).status == 403
    end

    test "revoked or expired, it is 401", ctx do
      hash = UserSession.hash_token(ctx.session)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      Repo.update_all(from(s in UserSession, where: s.token_hash == ^hash),
        set: [expires_at: past]
      )

      assert get_as(ctx.session, "/api/workspaces").status == 401

      revoked = login!(ctx.email)

      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> revoked)
      |> delete("/v1/auth/logout")

      assert get_as(revoked, projects(ctx.seated)).status == 401
    end

    test "a session in the cookie only (no bearer) is 401", ctx do
      resp =
        scoped_conn()
        |> Plug.Test.init_test_session(%{"user_session" => ctx.session})
        |> get("/api/workspaces")

      assert resp.status == 401
    end

    test "a bearer that is neither a token nor a session is 401" do
      assert get_as("not-a-credential", "/api/workspaces").status == 401
    end
  end

  describe "an API token (control)" do
    test "lists its own workspace and is refused 403 on another", ctx do
      assert ctx.other.slug in slugs(get_as(ctx.token, "/api/workspaces"), "workspaces")
      assert ctx.other_proj.slug in slugs(get_as(ctx.token, projects(ctx.other)), "projects")
      assert get_as(ctx.token, projects(ctx.seated)).status == 403
    end
  end
end
