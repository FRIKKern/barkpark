defmodule BarkparkCloud.Web.PromoteTest do
  @moduledoc """
  Rollback/redeploy as a control-plane primitive (charter decision 7):

      POST /v1/sites/:id/deployments/:dep_id/promote

  The load-bearing properties, all asserted here:

    * a PRODUCTION source mints a FRESH queued production deployment pinned to the
      source's git_ref + artifact_url (promote-by-NEW-deployment, never a pointer
      flip) — rolling back to an older artifact and redeploying the current one
      are the same primitive;
    * a PREVIEW source is not promotable → 422 (previews answer on their own host,
      never the production slot);
    * `sites.current_deployment_id` is UNTOUCHED — the live pointer stays
      agent-owned (the on-box agent flips it when the new row goes `live`);
    * the promote writes a `deployment.promoted` audit row (target = the new
      deployment, metadata carries the source);
    * the promote fires the `deployments` + `audit` SSE invalidations (decision 2
      — both are already in the closed event-type set) so every open dashboard tab
      refetches the deploy list and activity feed.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Events, Registry}
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "u-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    team
  end

  defp user_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token \\ nil) do
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

  # A production source that has already gone live — the realistic promote
  # target (superseded deployments stay terminal-`live`). Living at a terminal
  # status also keeps it out of the production active-ref unique index, so a
  # promote at the same git_ref mints cleanly.
  defp live_source(site, git_ref, artifact_url) do
    {:ok, d} = Registry.create_deployment(site, %{git_ref: git_ref, artifact_url: artifact_url})
    {:ok, d} = Registry.transition_deployment(d, %{status: "live"})
    d
  end

  describe "POST /v1/sites/:id/deployments/:dep_id/promote" do
    test "production source → mints a NEW queued production deployment pinned to source artifact" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      source = live_source(site, "v1-sha", "file:///tmp/v1.tar.gz")

      # The live pointer is agent-owned; pin it at the source and prove the
      # promote never touches it.
      {:ok, _} =
        site
        |> Ecto.Changeset.change(current_deployment_id: source.id)
        |> Repo.update()

      # Subscribe as a dashboard tab would: a successful promote must fire the
      # coarse invalidation events that tell every open tab to refetch.
      :ok = Events.subscribe(team.id)

      conn =
        call(:post, "/v1/sites/#{site.id}/deployments/#{source.id}/promote", %{}, token)

      assert conn.status == 201
      new = json_body(conn)["deployment"]

      # A genuinely new row — not the source, not a pointer flip.
      assert new["id"] != source.id
      assert new["status"] == "queued"
      assert new["environment"] == "production"

      # Pinned to the source's already-built artifact.
      assert new["git_ref"] == "v1-sha"
      assert new["artifact_url"] == "file:///tmp/v1.tar.gz"

      # The row is real and queued in the DB, ready for the fenced builder.
      reread = Registry.get_deployment(new["id"])
      assert reread.status == "queued"
      assert reread.environment == "production"
      assert reread.site_id == site.id

      # current_deployment_id is UNTOUCHED — still the source (agent flips it
      # only once the new deployment goes live).
      assert Registry.get_deployment(source.id).status == "live"
      assert Registry.get_site(site.id).current_deployment_id == source.id

      # An audit row was written for the promote, targeting the new deployment.
      events = Accounts.list_audit_events(team)
      promote = Enum.find(events, &(&1.action == "deployment.promoted"))
      assert promote
      assert promote.target_type == "deployment"
      assert promote.target_id == new["id"]
      assert promote.actor_user_id == user.id
      assert promote.metadata["source_deployment_id"] == source.id
      assert promote.metadata["git_ref"] == "v1-sha"

      # The deploy list + activity feed invalidations fired (decision 2 — both
      # types are already registered, no events.ex change). A tab that missed
      # them would render a stale deploy list after a rollback.
      assert_receive {:bpcloud_event, %{type: "deployments"}}
      assert_receive {:bpcloud_event, %{type: "audit"}}
    end

    test "rolling back to an OLDER artifact is the same primitive (older source → new queued prod)" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      old = live_source(site, "v1-sha", "file:///tmp/v1.tar.gz")
      _current = live_source(site, "v2-sha", "file:///tmp/v2.tar.gz")

      # Promote the OLDER deployment — a rollback.
      conn = call(:post, "/v1/sites/#{site.id}/deployments/#{old.id}/promote", %{}, token)

      assert conn.status == 201
      new = json_body(conn)["deployment"]
      assert new["git_ref"] == "v1-sha"
      assert new["artifact_url"] == "file:///tmp/v1.tar.gz"
      assert new["status"] == "queued"
    end

    test "a git_ref with a build already in flight → 409 build_in_progress (no duplicate, no audit)" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      # A production source at v1-sha that is STILL active (queued) — it holds the
      # production active-ref slot, so a promote at the same ref would collide on
      # the active-ref unique index. This is a state conflict, not bad input.
      {:ok, source} =
        Registry.create_deployment(site, %{
          git_ref: "v1-sha",
          artifact_url: "file:///tmp/v1.tar.gz"
        })

      assert source.status == "queued"

      conn = call(:post, "/v1/sites/#{site.id}/deployments/#{source.id}/promote", %{}, token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "build_in_progress"

      # The mint rolled back: still exactly the one source row, and no audit row
      # (the promote + audit share a transaction).
      assert length(Registry.list_deployments(site, 100, environment: "production")) == 1
      assert Accounts.list_audit_events(team) == []
    end

    test "source with no artifact and a site with no connected repo → 422 no_build_source" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)
      refute site.github_repo

      # A production source pinned to neither an artifact nor (via the site) a
      # connected repo — the promoted row could never build. Refuse it up front
      # rather than mint a queued row the stale-reaper only later flips to failed.
      {:ok, source} = Registry.create_deployment(site, %{git_ref: "v1-sha", artifact_url: nil})

      conn = call(:post, "/v1/sites/#{site.id}/deployments/#{source.id}/promote", %{}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "no_build_source"

      # No new row minted (still just the source), no audit row.
      assert length(Registry.list_deployments(site, 100, environment: "production")) == 1
      assert Accounts.list_audit_events(team) == []
    end

    test "preview source → 422 not_promotable" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      {:ok, preview} = Registry.create_preview_deployment(site, "feature/x", "branch-sha", nil)
      assert preview.environment == "preview"

      :ok = Events.subscribe(team.id)

      conn =
        call(:post, "/v1/sites/#{site.id}/deployments/#{preview.id}/promote", %{}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "not_promotable"

      # No new deployment minted, no audit row written.
      assert Registry.list_deployments(site, 100, environment: "production") == []
      assert Accounts.list_audit_events(team) == []

      # A rejected promote must NOT lie to the dashboard: no invalidation fires.
      refute_receive {:bpcloud_event, _}
    end

    test "nonexistent deployment id → 404" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      fake = Ecto.UUID.generate()

      conn = call(:post, "/v1/sites/#{site.id}/deployments/#{fake}/promote", %{}, token)
      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "non-UUID deployment id → 404 (no raised CastError)" do
      {user, team} = user_team()
      site = site_fixture(team)
      token = login_token(user)

      conn =
        call(:post, "/v1/sites/#{site.id}/deployments/not-a-uuid/promote", %{}, token)

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "a deployment from ANOTHER site → 404 (existence-leak protection)" do
      {user, team} = user_team()
      site_a = site_fixture(team)
      site_b = site_fixture(team)
      token = login_token(user)

      source = live_source(site_b, "v1-sha", "file:///tmp/v1.tar.gz")

      # Ask site_a to promote site_b's deployment — same 404 as a missing id.
      conn =
        call(:post, "/v1/sites/#{site_a.id}/deployments/#{source.id}/promote", %{}, token)

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end

    test "wrong-team site → 404" do
      {_user, team} = user_team()
      site = site_fixture(team)
      source = live_source(site, "v1-sha", "file:///tmp/v1.tar.gz")

      # A different team's user cannot see (or promote) this site.
      {other_user, _other_team} = user_team()
      token = login_token(other_user)

      conn =
        call(:post, "/v1/sites/#{site.id}/deployments/#{source.id}/promote", %{}, token)

      assert conn.status == 404
    end

    test "no auth → 401" do
      conn =
        call(
          :post,
          "/v1/sites/#{Ecto.UUID.generate()}/deployments/#{Ecto.UUID.generate()}/promote",
          %{}
        )

      assert conn.status == 401
    end
  end
end
