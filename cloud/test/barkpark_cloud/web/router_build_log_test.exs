defmodule BarkparkCloud.Web.RouterBuildLogTest do
  @moduledoc """
  `dr-bl-recorder-http-read-path` — the TEAM-SCOPED read path for the black box
  recorder, addressed BY DEPLOYMENT ID.

  THE HOLE THIS FILE PINS. Wave 2 made a failed deploy's build output durable and
  addressable on the box (`DeployRunner.build_record/2`, served by the box's own
  admin door under `record=1`), and the control plane never called it. `describe
  "the read path exists at all"` below is the RED-before test: on `origin/main`
  the route does not exist and `GET /v1/sites/:id/deployments/:dep_id/build-log`
  falls through the router to its catch-all.

  THE SECOND HOLE, and the one `dr-w19-site-build-log-is-operator-only` closed.
  The route shipped `Auth.require_platform_operator`-gated, which is the
  `:platform_admin_emails` allowlist — unset on prod, unsettable through any
  route, console action or User field (`gr-ops-platform-admin-emails`). This file
  used to say so and then set the allowlist in Application config so its own
  tests could pass, which proved the gate and the route while claiming nothing
  about production — where the answer for EVERY real account was 403. A team
  member whose site failed to build could not read why.

  It now takes `with_team_site(conn, {:ability, "read"}, …)`, the same door
  `GET /v1/sites/:id/deployments/:dep_id` uses. So the gate arms below are the
  ones that matter in production and not only in a test process:

    * a member of the team that owns the site reads it (200) — SESSION or a
      read-ability PAT, because the Go client sends a Bearer PAT;
    * a member of ANOTHER team gets 404, not 403 — existence-leak parity with
      every other `/v1/sites/:id/*` route;
    * a platform operator who is not a member of the owning team ALSO gets 404:
      the door is team-scoped, and operator-ness is no longer a key to it;
    * an anonymous caller gets 401.

  WHAT IS DELIBERATELY NOT ASSERTED. Nothing here claims the route serves raw log
  BYTES — it never has, and the widening did not change that. The box refuses
  them (the build env file carries `BARKPARK_TOKEN=` in plaintext) and §5 below
  pins the control plane's own field allowlist over the box's reply in both
  directions.

  `async: false` — one arm still writes the process-global operator allowlist, to
  prove operator-ness buys nothing here.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Repo
  alias BarkparkCloud.Sites.BuildLog
  alias BarkparkCloud.Sites.FakeBoxRelay
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures -----------------------------------------------------------------

  defp live_bp(team) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://bp-#{n}.barkpark.cloud",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> Repo.update!()
  end

  defp site_fixture(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro"
      })

    site
  end

  # Born, then driven TERMINAL. `deployments_active_site_env_index` allows one
  # ACTIVE deployment per (site, environment), and this row's whole subject is a
  # build that already finished — a failed one an operator comes back to days
  # later. `status` is deliberately not castable, so the transition is a direct
  # change, the same way the fixtures in `deploy_transition_detail_test.exs` reach
  # a terminal row.
  defp deployment_fixture(site, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, d} = Registry.create_deployment(site, Enum.into(attrs, %{build_id: "bld-#{n}"}))
    d |> Ecto.Changeset.change(status: "failed") |> Repo.update!()
  end

  # A user and the team they own — the shape every read arm needs, because the
  # site must belong to THIS user's team for the team-scoped door to open.
  defp member_fixture do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "member-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-m-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # A member of the owning team, plus that team's live instance, site and a
  # terminal deployment on it. One helper because every arm below needs the same
  # four rows and the ONLY thing that varies is who asks.
  defp owned_site do
    {user, team} = member_fixture()
    bp = live_bp(team)
    site = site_fixture(bp)
    dep = deployment_fixture(site)
    %{user: user, team: team, site: site, deployment: dep}
  end

  # A user of some OTHER team. Nothing about them touches the site under test.
  defp foreign_user_fixture do
    {user, _team} = member_fixture()
    user
  end

  # A platform operator — and, deliberately, NOT a member of the team that owns
  # the site under test. Writes the process-global allowlist, which is why this
  # file is `async: false`.
  defp operator_fixture do
    {user, _team} = member_fixture()
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    user
  end

  defp read_pat(user, team) do
    {:ok, token, _stored} =
      Accounts.create_personal_access_token(user, team, %{
        name: "build-log-read-#{System.unique_integer([:positive])}",
        abilities: ["read"]
      })

    token
  end

  # `user` may be nil (anonymous), a %User{} (minted a session token), or a
  # `{:token, binary}` pair — the PAT arm, which is the credential the Go client
  # actually presents.
  defp get_build_log(site_id, dep_id, user) do
    conn = conn(:get, "/v1/sites/#{site_id}/deployments/#{dep_id}/build-log")

    conn =
      case user do
        nil ->
          conn

        {:token, token} ->
          put_req_header(conn, "authorization", "Bearer #{token}")

        user ->
          {:ok, token} = Accounts.create_user_session_token(user)
          put_req_header(conn, "authorization", "Bearer #{token}")
      end

    Router.call(conn, @opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  ## 1. The hole ---------------------------------------------------------------

  describe "the read path exists at all (the RED-before arm)" do
    # THE MUTATION PROOF. Delete the `get "/v1/sites/:id/deployments/:dep_id/build-log"`
    # clause from the router and this test fails: the router's catch-all answers
    # 404 `not_found` with NO `deployment_id` key, because nothing resolved a
    # deployment. A 200 carrying the deployment's own id can only come from a
    # route that looked it up.
    test "a team member reads a recorded build by DEPLOYMENT ID and the answer names that deployment" do
      %{user: user, site: site, deployment: dep} = owned_site()

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "available")
      )

      conn = get_build_log(site.id, dep.id, user)

      assert conn.status == 200
      assert body(conn)["deployment_id"] == dep.id
      assert body(conn)["build_id"] == dep.build_id
      assert body(conn)["log_state"] == "available"
      assert body(conn)["available"] == true
    end

    # THE KEY IS THE DEPLOYMENT, NOT THE SLUG. A site that has deployed SINCE must
    # not move the answer: the older deployment's own build_id is what goes to the
    # box. This is the property the whole build_id keying exists for.
    test "a later deployment on the same site does not change what the older one reads" do
      {user, team} = member_fixture()
      bp = live_bp(team)
      site = site_fixture(bp)
      old = deployment_fixture(site, %{build_id: "bld-old"})
      _newer = deployment_fixture(site, %{build_id: "bld-new"})

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, "bld-old", "available")
      )

      conn = get_build_log(site.id, old.id, user)

      assert conn.status == 200
      assert body(conn)["build_id"] == "bld-old"

      # A POSITIVE FACT about what crossed the seam, not the absence of an error:
      # the box was asked for exactly the older build.
      assert [{:build_record, %{slug: slug, build_id: "bld-old"}}] = FakeBoxRelay.calls()
      assert slug == site.slug
    end
  end

  ## 2. Three distinguishable answers, never one 404 ---------------------------

  describe "'evicted' / 'never recorded' / 'no such deployment' are three answers" do
    setup do
      {user, team} = member_fixture()
      bp = live_bp(team)
      site = site_fixture(bp)
      %{user: user, site: site}
    end

    test "evicted is 410 and names when retention took it", %{user: user, site: site} do
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_record:
          FakeBoxRelay.terminal_record(site.slug, dep.build_id, "evicted",
            evicted_at: "2026-08-13T04:00:00Z"
          )
      )

      conn = get_build_log(site.id, dep.id, user)

      assert conn.status == 410
      assert body(conn)["error"] == "build_log_evicted"
      assert body(conn)["evicted_at"] == "2026-08-13T04:00:00Z"
      assert body(conn)["available"] == false
    end

    test "never recorded is 200 with a definite log_state", %{user: user, site: site} do
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "never_recorded")
      )

      conn = get_build_log(site.id, dep.id, user)

      assert conn.status == 200
      assert body(conn)["log_state"] == "never_recorded"
      assert body(conn)["available"] == false
    end

    test "no such deployment is 404 not_found", %{user: user, site: site} do
      conn = get_build_log(site.id, Ecto.UUID.generate(), user)

      assert conn.status == 404
      assert body(conn)["error"] == "not_found"
    end

    # THE CRITERION, ASSERTED AS ONE POSITIVE FACT: the three statuses are three
    # DIFFERENT numbers. Collapse any two and this compares equal and fails —
    # which is what a bare `assert status == 404` on each could never catch.
    test "the three statuses are pairwise distinct", %{user: user, site: site} do
      evicted = deployment_fixture(site)
      never = deployment_fixture(site)

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, evicted.build_id, "evicted")
      )

      evicted_status = get_build_log(site.id, evicted.id, user).status

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, never.build_id, "never_recorded")
      )

      never_status = get_build_log(site.id, never.id, user).status
      absent_status = get_build_log(site.id, Ecto.UUID.generate(), user).status

      assert Enum.sort([evicted_status, never_status, absent_status]) == [200, 404, 410]
    end

    # `missing` is the box's FOURTH state and must not be laundered into either of
    # the two claims above: retention did not do it, and it is not "never".
    test "missing is its own answer, not evicted and not never_recorded", %{
      user: user,
      site: site
    } do
      dep = deployment_fixture(site)

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "missing")
      )

      conn = get_build_log(site.id, dep.id, user)

      assert conn.status == 200
      assert body(conn)["log_state"] == "missing"
    end

    # An unreachable box is "we do not know" — never "nothing was recorded".
    test "an unreachable box is 502, not a log-state claim", %{user: user, site: site} do
      dep = deployment_fixture(site)
      FakeBoxRelay.program(build_record: {:error, :instance_error})

      conn = get_build_log(site.id, dep.id, user)

      assert conn.status == 502
      assert body(conn)["error"] == "box_unreachable"
      assert body(conn)["deployment_id"] == dep.id
      refute Map.has_key?(body(conn), "log_state")
    end
  end

  ## 3. The team gate ----------------------------------------------------------

  describe "the surface is team-scoped, not operator-gated (dr-w19-site-build-log-is-operator-only)" do
    # THE CLOSER'S OWN ARM. Put `Auth.require_platform_operator(conn, [])` back in
    # front of this route and this test reds with 403 where it expects 200: the
    # user is a real owner of the team that owns the site, and the operator
    # allowlist is EMPTY in this test — which is exactly prod's shape
    # (`gr-ops-platform-admin-emails`). The audience census's rot assertion is the
    # other half of the same proof, from source rather than from a request.
    test "a member of the owning team reads the log, with NO operator allowlist set" do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [])
      %{user: user, site: site, deployment: dep} = owned_site()

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "available")
      )

      conn = get_build_log(site.id, dep.id, user)

      assert conn.status == 200
      assert body(conn)["log_state"] == "available"
    end

    # `{:ability, "read"}`, not `:session`: `SiteBuildLog` in
    # internal/cloudclient/site_build_log.go sends a Bearer PAT. A session-only
    # door would leave the ONLY reader of this signal outside it — a different
    # empty audience wearing a nicer tier name.
    test "a read-ability PAT reaches it — the credential the Go client presents" do
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [])
      %{user: user, team: team, site: site, deployment: dep} = owned_site()

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "available")
      )

      conn = get_build_log(site.id, dep.id, {:token, read_pat(user, team)})

      assert conn.status == 200
      assert body(conn)["deployment_id"] == dep.id
    end

    # 404, NEVER 403 — existence-leak parity with every other /v1/sites/:id/*
    # route (`GET /v1/sites/:id/deployments/:dep_id` says the same thing in the
    # same words). And the box is never asked, which proves the gate sits in
    # front of the relay rather than behind it.
    test "a member of ANOTHER team gets 404, not 403, and the box is never asked" do
      %{site: site, deployment: dep} = owned_site()
      stranger = foreign_user_fixture()

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "available")
      )

      conn = get_build_log(site.id, dep.id, stranger)

      assert conn.status == 404
      assert body(conn)["error"] == "not_found"
      assert FakeBoxRelay.calls() == []
    end

    # BOTH DIRECTIONS OF THE RE-POINT IN ONE RUN. The arm above proves a team
    # member is now IN; this one proves the old key no longer opens anything it
    # should not: platform-operator-ness is not membership, so an operator who is
    # not on the owning team gets the same 404 a stranger does.
    test "a platform OPERATOR who is not on the owning team still gets 404" do
      %{site: site, deployment: dep} = owned_site()
      operator = operator_fixture()

      FakeBoxRelay.program(
        build_record: FakeBoxRelay.terminal_record(site.slug, dep.build_id, "available")
      )

      conn = get_build_log(site.id, dep.id, operator)

      assert conn.status == 404
      assert FakeBoxRelay.calls() == []
    end

    test "an anonymous caller gets 401" do
      %{site: site, deployment: dep} = owned_site()

      conn = get_build_log(site.id, dep.id, nil)

      assert conn.status == 401
    end
  end

  ## 4. Site scoping and unkeyed rows ------------------------------------------

  describe "scoping and pre-recorder rows" do
    test "a deployment belonging to ANOTHER site is 404 through this site's URL" do
      {user, team} = member_fixture()
      bp = live_bp(team)
      site_a = site_fixture(bp)
      site_b = site_fixture(bp)
      dep_b = deployment_fixture(site_b)

      conn = get_build_log(site_a.id, dep_b.id, user)

      assert conn.status == 404
      assert body(conn)["error"] == "not_found"
    end

    test "a pre-recorder deployment with no build_id answers never_recorded WITHOUT asking the box" do
      {user, team} = member_fixture()
      bp = live_bp(team)
      site = site_fixture(bp)
      dep = deployment_fixture(site, %{build_id: nil})

      FakeBoxRelay.program([])

      conn = get_build_log(site.id, dep.id, user)

      assert conn.status == 200
      assert body(conn)["log_state"] == "never_recorded"
      # A slug-only read would have handed back SOME OTHER build's record. It must
      # not happen, and the recorded call list is the positive proof it did not.
      assert FakeBoxRelay.calls() == []
    end
  end

  ## 5. The field allowlist ----------------------------------------------------

  describe "the box's reply is allowlisted, never passed through" do
    # A box that grows a field must not be able to publish it through this route.
    # BOTH ARMS: `failure_reason` (listed) survives, `log_tail` (not listed) does
    # not — a control proving the render READS is not proof it can WITHHOLD.
    test "a listed field survives and an unlisted one is dropped" do
      {status, rendered} =
        BuildLog.wire(
          {:ok, 200,
           %{
             "log_state" => "available",
             "failure_reason" => "BUILD failed (exit 12)",
             "log_tail" => "BARKPARK_TOKEN=bppat_deadbeefdeadbeefdeadbeef"
           }},
          "dep-1",
          "bld-1"
        )

      assert status == 200
      assert rendered.failure_reason == "BUILD failed (exit 12)"
      refute Map.has_key?(rendered, :log_tail)
      refute rendered |> inspect() |> String.contains?("bppat_")
    end

    test "an over-long failure reason is truncated VISIBLY, not silently" do
      long = String.duplicate("x", 40_000)

      {200, rendered} =
        BuildLog.wire(
          {:ok, 200, %{"log_state" => "available", "failure_reason" => long}},
          "dep-1",
          "bld-1"
        )

      assert byte_size(rendered.failure_reason) < byte_size(long)
      assert String.ends_with?(rendered.failure_reason, "…[truncated]")
    end

    test "a log_state this plane does not understand is 502, never a silent 200" do
      assert {502, %{error: "box_unreachable"}} =
               BuildLog.wire({:ok, 200, %{"log_state" => "quantum"}}, "dep-1", "bld-1")
    end
  end
end
