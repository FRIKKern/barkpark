defmodule BarkparkCloud.Web.RouterGithubReposTest do
  @moduledoc """
  The gh-3 "Create GitHub repo" surface:

      POST /v1/github/repos {template, name, private}

  Fake-backed end-to-end: connect (fake) → create a repo from blog-starter →
  the fake records the created repo + pushed files → response shape. Plus every
  honest gate: 401 / 403 no_team (the admin gate answers it) / 503
  not-configured / 409 no_installation /
  403 member / 422 invalid_name / 422 unknown_template.

  `async: false` — toggles the global `BarkparkCloud.GitHub` app env to simulate
  a wired App (the client stays the in-memory Fake, so it is €0).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, GitHub}
  alias BarkparkCloud.GitHub.Fake
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team(role) do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp configure_github do
    base = Application.get_env(:barkpark_cloud, GitHub, [])

    Application.put_env(
      :barkpark_cloud,
      GitHub,
      Keyword.merge(base, app_id: "test-app-id", private_key: "dummy-pem", app_slug: "bp-deploy")
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)
  end

  defp connect(team), do: {:ok, _} = GitHub.record_installation(team, "4242")

  describe "gates" do
    test "unauthenticated → 401" do
      assert call(:post, "/v1/github/repos", %{template: "blog-starter", name: "x"}, nil).status ==
               401
    end

    test "authed but teamless → 403 (admin gate rejects a user with no team)" do
      user = user_fixture()
      configure_github()

      conn =
        call(:post, "/v1/github/repos", %{template: "blog-starter", name: "x"}, login_token(user))

      assert conn.status == 403
    end

    test "credentials absent → 503 feature_not_configured" do
      {user, _team} = user_with_team("owner")

      conn =
        call(:post, "/v1/github/repos", %{template: "blog-starter", name: "x"}, login_token(user))

      assert conn.status == 503
      assert body(conn)["error"] == "feature_not_configured"
    end

    test "configured but not connected → 409 no_installation" do
      configure_github()
      {user, _team} = user_with_team("owner")

      conn =
        call(:post, "/v1/github/repos", %{template: "blog-starter", name: "x"}, login_token(user))

      assert conn.status == 409
      assert body(conn)["error"] == "no_installation"
    end

    test "member → 403 (RBAC: admin only)" do
      configure_github()
      {user, team} = user_with_team("member")
      connect(team)

      conn =
        call(:post, "/v1/github/repos", %{template: "blog-starter", name: "x"}, login_token(user))

      assert conn.status == 403
    end

    test "invalid repo name → 422 invalid_name" do
      configure_github()
      {user, team} = user_with_team("owner")
      connect(team)

      conn =
        call(
          :post,
          "/v1/github/repos",
          %{template: "blog-starter", name: "bad name!"},
          login_token(user)
        )

      assert conn.status == 422
      assert body(conn)["error"] == "invalid_name"
    end

    test "unknown / non-deployable template → 422 unknown_template" do
      configure_github()
      {user, team} = user_with_team("owner")
      connect(team)

      # place-directory is in the public catalog but ships no deployable app tree.
      conn =
        call(
          :post,
          "/v1/github/repos",
          %{template: "place-directory", name: "dir"},
          login_token(user)
        )

      assert conn.status == 422
      assert body(conn)["error"] == "unknown_template"
    end
  end

  describe "create (fake-backed end to end)" do
    test "owner + connected + blog-starter → 201, repo created, app files pushed" do
      configure_github()
      {user, team} = user_with_team("owner")
      connect(team)
      Fake.reset()

      conn =
        call(
          :post,
          "/v1/github/repos",
          %{template: "blog-starter", name: "my-blog", private: true},
          login_token(user)
        )

      assert conn.status == 201
      b = body(conn)

      # Response shape: the repo the Vercel handoff will clone.
      assert b["repo_full_name"] == "octo-4242/my-blog"
      assert b["html_url"] == "https://github.com/octo-4242/my-blog"
      assert b["pushed"] > 0
      assert is_list(b["steps"]) and length(b["steps"]) == 2

      # The fake recorded the repo creation…
      assert [%{"full_name" => "octo-4242/my-blog", "private" => true}] = Fake.created_repos()

      # …and the file push. The pushed batch carries the deployable app.
      assert [%{repo: "octo-4242/my-blog", files: files, message: message}] = Fake.pushes()
      paths = Enum.map(files, & &1.path)
      assert "package.json" in paths
      assert "barkpark.template.json" in paths
      assert ".gitignore" in paths
      refute Enum.any?(paths, &String.ends_with?(&1, ".tmpl"))
      assert message =~ "blog-starter"
      assert length(files) == b["pushed"]

      # package.json carries the repo name, no unfilled placeholder.
      pkg = Enum.find(files, &(&1.path == "package.json"))
      assert pkg.content =~ ~s("name": "my-blog")
      refute pkg.content =~ "{{"
    end

    test "private defaults to false when omitted" do
      configure_github()
      {user, team} = user_with_team("owner")
      connect(team)
      Fake.reset()

      conn =
        call(
          :post,
          "/v1/github/repos",
          %{template: "website-starter", name: "site"},
          login_token(user)
        )

      assert conn.status == 201
      assert [%{"private" => false}] = Fake.created_repos()
    end
  end
end
