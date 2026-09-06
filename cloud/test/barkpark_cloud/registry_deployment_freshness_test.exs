defmodule BarkparkCloud.RegistryDeploymentFreshnessTest do
  @moduledoc """
  stw4-freshness (charter D24): `Registry.latest_deployment_status_map/1` — the
  batched embed behind the dashboard site-row freshness badge.

  Proves, against the real Sandbox:

  * newest-row-wins per site (DISTINCT ON site_id, inserted_at DESC) — an older
    deployment never shadows the freshest one;
  * the map is SLIM and HONEST — status/trigger/timestamps only, never console /
    build_log_url / content_rev (the HONESTY LAW);
  * sites with no deployment are simply absent (nil-honest at the caller);
  * empty ids short-circuits to an empty map (no query).
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp site_fixture(barkpark) do
    n = System.unique_integer([:positive])
    {:ok, site} = Registry.create_site(barkpark, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  defp setup_site do
    team_fixture() |> barkpark_fixture() |> site_fixture()
  end

  # Backdate a deployment's inserted_at so a later insert is unambiguously newer.
  defp backdate(deployment_id, seconds) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-seconds, :second)
      |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(d in Deployment, where: d.id == ^deployment_id),
      set: [inserted_at: at]
    )
  end

  test "empty ids short-circuit to an empty map" do
    assert Registry.latest_deployment_status_map([]) == %{}
  end

  test "newest deployment wins per site (older row never shadows the freshest)" do
    site = setup_site()

    # The older row is SETTLED — deploy-truth W1 re-keyed the active index onto
    # (site_id, environment), so a site has at most one build in flight and a
    # second active row is refused whatever its git_ref. The map must still pick
    # the newest.
    {:ok, old} = Registry.create_deployment(site, %{git_ref: "v1", trigger: "manual"})
    {:ok, old} = Registry.transition_deployment(old, %{status: "failed"})
    backdate(old.id, 3600)

    {:ok, _new} =
      Registry.create_deployment(site, %{git_ref: "v2", trigger: "content-auto"})

    map = Registry.latest_deployment_status_map([site.id])

    assert %{status: "queued", trigger: "content-auto"} = map[site.id]
    assert %DateTime{} = map[site.id].inserted_at
    assert %DateTime{} = map[site.id].updated_at
  end

  # The keyset law is PINNED, not frozen. It grew by the CAUSE PAIR (`stage` +
  # the RAW `failure_reason`) because that pair is the INPUT
  # `DeployLedger.classify/1` reads: a select carrying a subset classifies
  # EVERY row `UNCLASSIFIED` while looking like it works. Both are INTERNAL —
  # the only caller (`GET /v1/sites`) folds the reason through
  # `FailureCopy.humanize/1` before a reader sees it. What the law actually
  # FORBIDS is unchanged and is asserted below the keyset.
  test "HONESTY LAW: the slim map carries the display keys plus the cause pair" do
    site = setup_site()
    {:ok, _d} = Registry.create_deployment(site, %{git_ref: "main", trigger: "manual"})

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

  test "a site with no deployment is absent from the map (nil-honest)" do
    with_dep = setup_site()
    no_dep = setup_site()
    {:ok, _d} = Registry.create_deployment(with_dep, %{git_ref: "main"})

    map = Registry.latest_deployment_status_map([with_dep.id, no_dep.id])

    assert Map.has_key?(map, with_dep.id)
    refute Map.has_key?(map, no_dep.id)
  end

  test "distinct sites each get their own latest row (batched)" do
    a = setup_site()
    b = setup_site()
    {:ok, _da} = Registry.create_deployment(a, %{git_ref: "main", trigger: "manual"})
    {:ok, _db} = Registry.create_deployment(b, %{git_ref: "main", trigger: "content-auto"})

    map = Registry.latest_deployment_status_map([a.id, b.id])

    assert map[a.id].trigger == "manual"
    assert map[b.id].trigger == "content-auto"
  end
end
