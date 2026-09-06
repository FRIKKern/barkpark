defmodule BarkparkCloud.Web.RouterSitesShippedCapabilityTest do
  @moduledoc """
  ssw8-bl-accepted-frameworks-no-implementation — `POST /v1/sites` refuses a
  framework the spawner cannot build and a scale_mode the runtime cannot honour.

  Before this, `bp cloud site create --framework hugo` answered 201 and printed
  a created receipt: `@static_frameworks` listed hugo, `@container_frameworks`
  listed nuxt and sveltekit, `@scale_modes` listed zero — and NONE of the four
  had anything behind it. `templates/` on main ships astro-starter and
  next-starter and nothing else; `grep -rn scale_mode cloud/lib` finds `zero`
  cast, stored and echoed on the wire, read by no waker and no idle-stop path.
  The row was a stored lie: a site that could never deploy.

  The ruling (lane lead-console-8) was FAIL CLOSED AT THE DOOR — 422, naming the
  shipped list for that kind — over the "201 + not yet deployable" alternative,
  which would have needed new copy on three surfaces to carry a site that can
  never work.

  One test PER value the enum used to accept, each through the REAL route:
  hugo, nuxt, sveltekit, scale_mode zero. Plus a positive control per kind, so a
  door that simply refuses everything cannot pass this file.

  What is deliberately NOT tested here as a refusal: an EXISTING row carrying
  one of these values. `site_test.exs` covers that — the gate reads `get_change`,
  so a stored hugo site still saves its env and attaches its domains. Only the
  door refuses.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"
  @instance_admin_token "instance-admin-token-plaintext"

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "user-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> BarkparkCloud.Repo.update!()
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Program ONLY the mint, so a static create that reaches the instance succeeds
  # with an `unverified` binding. Used by the positive control — and by the hugo
  # case, where it must never be reached at all.
  defp program_mint do
    StudioLinkFakeHttpClient.program(%{
      "/w/acme/p/blog/v1/tokens" =>
        {:ok, %{status: 201, body: ~s({"token":"bpt_public_read_minted"})}}
    })
  end

  defp static_body(framework, extra \\ %{}) do
    Map.merge(
      %{
        name: "blog",
        kind: "static",
        framework: framework,
        workspace: "acme",
        project: "blog",
        dataset: "production"
      },
      extra
    )
  end

  describe "POST /v1/sites refuses a framework with no shipped builder" do
    test "hugo (static) → 422 naming the static menu, and NO row is written" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)
      program_mint()

      conn = call(:post, "/v1/sites", Map.put(static_body("hugo"), :barkpark_id, bp.id), token)

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid"
      [detail] = body["details"]["framework"]
      assert detail =~ "no shipped builder"
      # The body NAMES what a static site CAN be created with.
      assert detail =~ "astro"
      assert detail =~ "static"
      refute detail =~ "hugo"

      # The refusal is a DOOR: no site row, and the site never touched the
      # instance to mint a token it would then have orphaned.
      assert Registry.list_sites_for_team(team) == []
    end

    test "nuxt (container) → 422 naming the container menu" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "shop", kind: "container", framework: "nuxt"},
          token
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid"
      [detail] = body["details"]["framework"]
      assert detail =~ "no shipped builder"
      assert detail =~ "nextjs"
      refute detail =~ "nuxt"
      assert Registry.list_sites_for_team(team) == []
    end

    test "sveltekit (container) → 422 naming the container menu" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "shop", kind: "container", framework: "sveltekit"},
          token
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid"
      [detail] = body["details"]["framework"]
      assert detail =~ "no shipped builder"
      assert detail =~ "nextjs"
      refute detail =~ "sveltekit"
      assert Registry.list_sites_for_team(team) == []
    end

    test "sveltekit on a NODE site is refused too — the node kind reuses the same list" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)
      program_mint()

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "ssr",
            kind: "node",
            framework: "sveltekit",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 422
      [detail] = json_body(conn)["details"]["framework"]
      assert detail =~ "a node site can be created with: nextjs"
      assert Registry.list_sites_for_team(team) == []
    end
  end

  describe "POST /v1/sites refuses a scale_mode with no runtime" do
    test "scale_mode zero → 422 naming always_on" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "shop", framework: "nextjs", scale_mode: "zero"},
          token
        )

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid"
      [detail] = body["details"]["scale_mode"]
      assert detail =~ "no runtime"
      assert detail =~ "always_on"
      assert Registry.list_sites_for_team(team) == []
    end

    test "an out-of-vocabulary scale_mode still reports the ORIGINAL inclusion error, not the new one" do
      # `burst` was never stored-legal. The new gate must not swallow the
      # pre-existing message and hand the caller a menu of "shipped" values for a
      # word the schema does not know at all.
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "shop", framework: "nextjs", scale_mode: "burst"},
          token
        )

      assert conn.status == 422
      [detail] = json_body(conn)["details"]["scale_mode"]
      refute detail =~ "no runtime"
    end
  end

  describe "the positive controls — the door refuses the four, and nothing else" do
    test "container + nextjs still 201s" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "shop", kind: "container", framework: "nextjs"},
          token
        )

      assert conn.status == 201
      assert json_body(conn)["site"]["framework"] == "nextjs"
    end

    test "static + astro still 201s" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)
      program_mint()

      conn = call(:post, "/v1/sites", Map.put(static_body("astro"), :barkpark_id, bp.id), token)

      assert conn.status == 201
      assert json_body(conn)["site"]["framework"] == "astro"
    end

    test "static + static (the starterless, no-build framework) still 201s" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)
      program_mint()

      conn = call(:post, "/v1/sites", Map.put(static_body("static"), :barkpark_id, bp.id), token)

      assert conn.status == 201
      assert json_body(conn)["site"]["framework"] == "static"
    end

    test "node + nextjs still 201s" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)
      program_mint()

      conn =
        call(
          :post,
          "/v1/sites",
          %{
            barkpark_id: bp.id,
            name: "ssr",
            kind: "node",
            framework: "nextjs",
            workspace: "acme",
            project: "blog",
            dataset: "production"
          },
          token
        )

      assert conn.status == 201
      assert json_body(conn)["site"]["framework"] == "nextjs"
    end

    test "an explicit scale_mode always_on still 201s" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites",
          %{barkpark_id: bp.id, name: "shop", framework: "nextjs", scale_mode: "always_on"},
          token
        )

      assert conn.status == 201
      assert json_body(conn)["site"]["scale_mode"] == "always_on"
    end
  end

  describe "stored rows are untouched — only the door refuses" do
    test "an EXISTING hugo site still loads, serializes and lists" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)

      # The pre-door shape: written the way the enum used to allow. Inserted
      # under `changeset/2` with framework as a CHANGE would now be refused, so
      # this row is minted the only honest way — as history, straight to the DB.
      site = legacy_site(bp, team, "hugo", "zero")

      conn =
        conn(:get, "/v1/sites/#{site.id}")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(@opts)

      assert conn.status == 200
      assert json_body(conn)["site"]["framework"] == "hugo"
      assert json_body(conn)["site"]["scale_mode"] == "zero"

      list =
        conn(:get, "/v1/sites")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(@opts)

      assert list.status == 200
      assert [%{"framework" => "hugo"}] = json_body(list)["sites"]
    end

    test "an EXISTING hugo site can still have a domain attached (changeset/2 on a loaded row)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)
      site = legacy_site(bp, team, "hugo", "zero")

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "legacy.example.com"}, token)

      assert conn.status in [200, 201],
             "attaching a domain to a stored hugo site must not be refused by the create door: " <>
               inspect(json_body(conn))

      assert "legacy.example.com" in Registry.get_site(site.id).domains
    end

    test "an EXISTING zero site can still have its env set" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      token = login_token(user)
      site = legacy_site(bp, team, "nextjs", "zero")

      conn = call(:post, "/v1/sites/#{site.id}/env", %{env: %{"API_KEY" => "k"}}, token)

      assert conn.status in [200, 201],
             "setting env on a stored zero-scale site must not be refused: " <>
               inspect(json_body(conn))
    end
  end

  # A row in the shape the enum used to permit. Written with an Ecto changeset
  # that does NOT run `Site.changeset/2`'s validations — that is the point: these
  # rows exist in production and predate the door.
  defp legacy_site(bp, team, framework, scale_mode) do
    n = System.unique_integer([:positive])

    %Registry.Site{}
    |> Ecto.Changeset.change(%{
      name: "Legacy #{n}",
      slug: "legacy-#{n}",
      kind: if(framework in ~w(nextjs nuxt sveltekit), do: "container", else: "static"),
      framework: framework,
      scale_mode: scale_mode,
      content_binding_verdict: "never_checked",
      barkpark_id: bp.id,
      team_id: team.id
    })
    |> BarkparkCloud.Repo.insert!()
  end
end
