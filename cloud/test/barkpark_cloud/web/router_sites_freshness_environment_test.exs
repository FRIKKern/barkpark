defmodule BarkparkCloud.Web.RouterSitesFreshnessEnvironmentTest do
  @moduledoc """
  cch-w14-s6: the fleet freshness badge must not quote a torn-down PREVIEW as
  the site's PRODUCTION state.

  `Registry.latest_deployment_status_map/1` (the batched embed behind
  `GET /v1/sites` → `last_deployment`) took the newest deployment row of ANY
  environment, while `GET /v1/sites/:id/deployments` filters to
  `environment: "production"`. A site with a LIVE production deployment and a
  newer CANCELLED branch preview therefore reported "cancelled" on the fleet
  list and "live" on the detail ladder — the same conn, the same instant, two
  answers. A person read Cancelled beside a site that is, in production, live,
  and could not click through to the state they were shown.

  This drives BOTH read paths on ONE fixture and pins them to AGREE. The
  fixture builds the cancelled preview from the PUBLIC api — no webhook/HMAC
  scaffolding: `create_preview_deployment/3` then `teardown_branch_previews/2`.

  Also pinned here, because the fix has exactly one visible consequence: a site
  whose ONLY deployments are previews now leaves the map entirely and carries
  `last_deployment: null` — the console paints its neutral never-deployed pill
  rather than a preview-derived badge.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
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

  defp call(method, path, token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Backdate a row so a later insert is unambiguously newer.
  defp backdate(deployment_id, seconds) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-seconds, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(from(d in Deployment, where: d.id == ^deployment_id), set: [inserted_at: at])
  end

  # A LIVE production deployment, backdated an hour.
  defp live_production_deployment(site) do
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main", trigger: "manual"})

    d =
      d
      |> Ecto.Changeset.change(status: "live")
      |> Repo.update!()

    backdate(d.id, 3600)
    # Reload — `backdate/2` writes through update_all, so the in-memory struct
    # still carries the pre-backdate timestamp.
    Repo.get!(Deployment, d.id)
  end

  # A CANCELLED branch preview, created NOW — the public-api path: open the
  # preview, then tear the branch down (the branch-delete webhook's effect).
  defp cancelled_preview(site, branch) do
    {:ok, dep} =
      Registry.create_preview_deployment(site, branch, String.duplicate("a", 40))

    1 = Registry.teardown_branch_previews(site, branch)
    Repo.get!(Deployment, dep.id)
  end

  describe "the fleet badge and the deploy ladder agree on the production state" do
    test "a cancelled preview newer than a live production deploy does not become the badge" do
      {user, team} = user_with_team()
      site = site_fixture(team)
      token = login_token(user)

      live = live_production_deployment(site)
      preview = cancelled_preview(site, "feat/x")

      # The fixture really is what the name says.
      assert preview.environment == "preview"
      assert preview.status == "cancelled"
      assert DateTime.compare(preview.inserted_at, live.inserted_at) == :gt

      # Read path A — the fleet list's batched freshness embed.
      list = call(:get, "/v1/sites", token)
      assert list.status == 200

      row =
        json_body(list)["sites"]
        |> Enum.find(&(&1["id"] == site.id))

      # Read path B — the site's own production deploy ladder.
      ladder = call(:get, "/v1/sites/#{site.id}/deployments", token)
      assert ladder.status == 200
      deployments = json_body(ladder)["deployments"]

      # The one assertion this file exists for: same site, same instant, ONE
      # answer. (Before `where: d.environment == "production"` landed on
      # `latest_deployment_status_map/1`, the fleet row said "cancelled" while
      # the ladder said "live".)
      assert row["last_deployment"]["status"] == "live"
      assert hd(deployments)["status"] == "live"
      assert row["last_deployment"]["status"] == hd(deployments)["status"]

      # The preview is not silently gone — it simply is not the site's
      # production state. It stays reachable on the unfiltered listing.
      assert Enum.any?(
               Registry.list_deployments(site, 100),
               &(&1.id == preview.id and &1.status == "cancelled")
             )
    end

    test "the map itself takes the live production row, not the newer preview" do
      {_user, team} = user_with_team()
      site = site_fixture(team)
      live = live_production_deployment(site)
      _preview = cancelled_preview(site, "feat/y")

      entry = Registry.latest_deployment_status_map([site.id])[site.id]

      assert entry.status == "live"
      assert entry.trigger == "manual"
      assert DateTime.compare(entry.inserted_at, live.inserted_at) == :eq
    end

    test "THE VISIBLE CONSEQUENCE: a preview-only site has no last_deployment embed" do
      {user, team} = user_with_team()
      site = site_fixture(team)
      token = login_token(user)

      _preview = cancelled_preview(site, "feat/only")

      # The map drops it entirely …
      refute Map.has_key?(Registry.latest_deployment_status_map([site.id]), site.id)

      # … so the fleet row is nil-honest, and the console paints its neutral
      # never-deployed pill instead of a preview-derived badge.
      row =
        call(:get, "/v1/sites", token)
        |> json_body()
        |> Map.fetch!("sites")
        |> Enum.find(&(&1["id"] == site.id))

      assert row["last_deployment"] == nil
    end

    # The keyset law is PINNED, not frozen: it grew by the CAUSE PAIR (`stage` +
    # the RAW `failure_reason`), which is the INPUT `DeployLedger.classify/1`
    # needs — a select carrying a subset classifies every row `UNCLASSIFIED`
    # while looking like it works. What the law actually forbids is unchanged
    # and is asserted below the keyset: no build internals, and no
    # `environment` (the query FILTERS on it; the embed must not claim it).
    test "HONESTY LAW holds: the map carries the four display keys plus the cause pair" do
      {_user, team} = user_with_team()
      site = site_fixture(team)
      _live = live_production_deployment(site)
      _preview = cancelled_preview(site, "feat/z")

      entry = Registry.latest_deployment_status_map([site.id])[site.id]

      assert Map.keys(entry) |> Enum.sort() == [
               :failure_reason,
               :inserted_at,
               :stage,
               :status,
               :trigger,
               :updated_at
             ]

      refute Map.has_key?(entry, :environment)
      refute Map.has_key?(entry, :console)
      refute Map.has_key?(entry, :build_log_url)
      refute Map.has_key?(entry, :content_rev)
    end
  end
end
