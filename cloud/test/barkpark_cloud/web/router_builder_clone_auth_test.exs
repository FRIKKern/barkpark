defmodule BrokenGitHubClient do
  @moduledoc """
  A `GitHub.Client` whose token exchange returns a shape the caller does not
  expect — the "seam drifted / upstream returned something new" case. Only
  `record_installation/2`'s validation call and the token exchange are needed
  here; the rest raise if anything reaches for them.
  """
  @behaviour BarkparkCloud.GitHub.Client

  @impl true
  def get_installation(id), do: {:ok, %{account_login: "octo-#{id}"}}

  @impl true
  def exchange_installation_token(_id), do: {:ok, nil}

  @impl true
  def create_repo(_id, _name, _private?), do: {:error, :unsupported}

  @impl true
  def push_files(_id, _repo, _files, _msg), do: {:error, :unsupported}

  @impl true
  def register_webhook(_id, _repo, _url, _secret), do: {:error, :unsupported}

  @impl true
  def list_repos(_id), do: {:error, :unsupported}
end

defmodule BarkparkCloud.Web.RouterBuilderCloneAuthTest do
  @moduledoc """
  dwb-webhook-deploy-artifact-gap — the AUTHENTICATED half of the git-ref clone
  lane.

  A GitHub push webhook mints an artifact-less `queued` Deployment and the
  builder-claim envelope hands the builder a clone recipe
  (`builder_claim_source/1`). That recipe was ANONYMOUS
  (`https://github.com/owner/repo.git`), so push-to-deploy could only ever
  succeed for a PUBLIC repo — the exact repos "Deploy with Barkpark" creates
  privately (`POST /v1/github/repos {"private": true}`) and the exact repos the
  Import-Git picker lists (`GET /v1/github/repos` returns `private`) were
  undeployable, failing at the builder's fetch with `could not read Username`
  → a terminal "not anonymously accessible".

  These tests pin the fix: when the site's team has a connected GitHub
  installation AND the App is wired, the worker-gated claim envelope carries a
  short-lived installation token, and it NEVER leaks anywhere else.

  `async: false` — `configure_github/0` mutates application env.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, GitHub, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  # jpf-w1-builder-identity: the builder claim is agent-gated and box-scoped, so
  # the credential is the token of the box hosting THIS site — not a fleet
  # secret. Memoised per box: mint_agent_token/3 supersedes the previous live
  # token of the same scope, so minting twice for one box would revoke the token
  # an earlier line is still holding.
  @installation_id "424242"

  defp user_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Simulate a wired GitHub App so `configured?/0` is true. The client stays the
  # in-memory Fake — token exchange is deterministic and costs nothing.
  defp configure_github do
    base = Application.get_env(:barkpark_cloud, GitHub, [])

    Application.put_env(
      :barkpark_cloud,
      GitHub,
      Keyword.merge(base, app_id: "test-app-id", private_key: "dummy-pem", app_slug: "bp-deploy")
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)
  end

  defp call(method, path, body \\ nil, token \\ nil) do
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

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # A team + site wired exactly like a real "Deploy with Barkpark" connection:
  # GitHub App installed for the team, repo linked with a webhook secret.
  defp connected_site do
    {user, team} = user_team()
    {:ok, _inst} = GitHub.record_installation(team, @installation_id)
    site = site_fixture(team)
    {:ok, site} = Registry.set_site_github(site, "owner/private-repo", "main", "hook-secret")
    {user, team, site}
  end

  defp agent_token(%Registry.Site{barkpark_id: bp_id}) do
    case Process.get({:agent_token, bp_id}) do
      nil ->
        {:ok, token, _} = Registry.mint_agent_token(bp_id, "report")
        Process.put({:agent_token, bp_id}, token)
        token

      token ->
        token
    end
  end

  defp claim(site, worker \\ "clone-auth-w") do
    call(:post, "/v1/builder/claim", %{worker_id: worker}, agent_token(site))
  end

  defp fake_token do
    {:ok, token} = GitHub.client().exchange_installation_token(@installation_id)
    token
  end

  describe "builder claim envelope — authenticated clone source" do
    setup do
      configure_github()
      :ok
    end

    test "a push on a connected repo yields a claim source carrying an installation token" do
      {_user, team, site} = connected_site()
      assert GitHub.connected?(team), "fixture must have a connected installation"

      sha = String.duplicate("ab", 20)
      {:ok, dep} = Registry.create_deployment(site, %{git_ref: sha, artifact_url: nil})

      conn = claim(site)
      assert conn.status == 200
      body = json_body(conn)
      assert body["deployment"]["id"] == dep.id

      source = body["source"]
      assert source["kind"] == "git"
      assert source["url"] == "https://github.com/owner/private-repo.git"
      assert source["ref"] == sha

      # THE GAP: without this the builder fetches anonymously and a private
      # repo can never build.
      assert source["token"] == fake_token()
      assert is_binary(source["token"]) and source["token"] != ""

      # The URL stays credential-free: the token rides its own field so it can
      # never be persisted into the clone workdir's config or echoed by git.
      refute source["url"] =~ fake_token()
    end

    test "the source URL never embeds the credential" do
      {_user, _team, site} = connected_site()
      {:ok, _} = Registry.create_deployment(site, %{git_ref: String.duplicate("cd", 20)})

      source = json_body(claim(site))["source"]
      assert source["url"] == "https://github.com/owner/private-repo.git"
      refute source["url"] =~ "@github.com"
      refute source["url"] =~ "x-access-token"
    end

    test "no installation → anonymous source, unchanged (public repos still build)" do
      {_user, team} = user_team()
      site = site_fixture(team)
      {:ok, site} = Registry.set_site_github(site, "owner/public-repo", "main", "hook-secret")
      {:ok, _} = Registry.create_deployment(site, %{git_ref: String.duplicate("ef", 20)})

      source = json_body(claim(site))["source"]
      assert source["kind"] == "git"
      assert source["url"] == "https://github.com/owner/public-repo.git"
      refute Map.has_key?(source, "token")
    end

    test "an artifact-backed row still has no clone source at all" do
      {_user, _team, site} = connected_site()

      {:ok, _} =
        Registry.create_deployment(site, %{
          git_ref: "v1",
          artifact_url: "file:///srv/artifacts/site.tar.gz"
        })

      refute Map.has_key?(json_body(claim(site)), "source")
    end
  end

  describe "the App is not wired" do
    test "an installation row alone does NOT mint a token (the Fake must never answer for prod)" do
      # No configure_github/0 here: `GitHub.configured?/0` is false, so the
      # configured client is the in-memory Fake standing in for a GitHub App
      # that does not exist. Handing the builder a `ghs_fake_…` string would
      # turn a working PUBLIC-repo clone into a 401 against real github.com.
      {_user, _team, site} = connected_site()
      refute GitHub.configured?()
      {:ok, _} = Registry.create_deployment(site, %{git_ref: String.duplicate("ba", 20)})

      source = json_body(claim(site))["source"]
      assert source["url"] == "https://github.com/owner/private-repo.git"
      refute Map.has_key?(source, "token")
    end
  end

  describe "a broken GitHub seam must never stall the build queue" do
    setup do
      configure_github()
      :ok
    end

    test "an unexpected client return degrades to an anonymous clone, not a 500" do
      # The mint runs INSIDE the builder's claim. A 500 here stalls the queue
      # for every tenant on the fleet — strictly worse than the gap being
      # fixed — so the arm that swallows an unknown seam shape is pinned.
      base = Application.get_env(:barkpark_cloud, GitHub, [])
      Application.put_env(:barkpark_cloud, GitHub, Keyword.put(base, :client, BrokenGitHubClient))
      on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)

      {_user, team} = user_team()
      {:ok, _} = GitHub.record_installation(team, @installation_id)
      site = site_fixture(team)
      {:ok, site} = Registry.set_site_github(site, "owner/private-repo", "main", "hook-secret")
      {:ok, _} = Registry.create_deployment(site, %{git_ref: String.duplicate("ab", 20)})

      conn = claim(site)
      assert conn.status == 200
      source = json_body(conn)["source"]
      assert source["url"] == "https://github.com/owner/private-repo.git"
      refute Map.has_key?(source, "token")
    end
  end

  describe "TENANCY — the credential rides ONLY the worker-gated claim" do
    setup do
      configure_github()
      :ok
    end

    test "tenant-facing deployment reads never carry the clone source or the token" do
      {user, _team, site} = connected_site()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      sha = String.duplicate("ab", 20)
      {:ok, dep} = Registry.create_deployment(site, %{git_ref: sha, artifact_url: nil})
      token = fake_token()

      list = call(:get, "/v1/sites/#{site.id}/deployments", nil, user_token)
      assert list.status == 200
      refute list.resp_body =~ token
      refute list.resp_body =~ "x-access-token"

      get = call(:get, "/v1/sites/#{site.id}/deployments/#{dep.id}", nil, user_token)
      assert get.status == 200
      refute get.resp_body =~ token
    end
  end
end
