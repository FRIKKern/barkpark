defmodule BarkparkCloud.DemandCensusTest do
  @moduledoc """
  dr-w13-bl-demand-needs-a-label-before-a-cut (charter D206): the CENSUS half.

  THE BEFORE NUMBER MOVES INSIDE THE INSTRUMENT. The 24h measurement this epic
  is blocked on — 2,438 attempts, 2,398 of them (98.4%) on five demo sites
  (live-auto 509, search-capstone 491, astro-search 471, search-ember 468,
  search 459), six sites at ZERO — lived as prose in a ledger row and SQL in a
  transcript. This file reproduces that exact shape as a fixture and asserts
  `DemandCensus.census/1` re-derives every figure from the new label, so the
  BEFORE number has a producer and an AFTER number is a diff rather than an
  argument.

  Also proved:

  * `platform_share` (label-derived) and `top_site_share` (rank-derived, blind
    to the label) CONVERGE on the same 98.4% — the label re-derives the
    concentration rather than restating it;
  * `unclassified` and `unlabelled` are reported separately and never folded
    into `customer`;
  * the census reads what the WRITER stamps, end to end through
    `Registry.create_deployment/2`.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, DemandCensus}

  # The measured 24h window, verbatim.
  @demo_sites [
    {"live-auto", 509},
    {"search-capstone", 491},
    {"astro-search", 471},
    {"search-ember", 468},
    {"search", 459}
  ]
  @demo_total 2398
  @customer_total 40
  @window_total 2438
  @zero_sites 6

  defp site_fixture(slug_hint) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: slug_hint, slug: "#{slug_hint}-#{n}"})
    site
  end

  # Bulk attempts, written straight to the table. The WRITER path is proved by
  # its own arm below; this one exists to reproduce a 2,438-row window without
  # 2,438 round trips.
  defp attempts(site, class, n) do
    now = DateTime.utc_now()

    rows =
      for i <- 1..n do
        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: "failed",
          environment: "production",
          trigger: "content-auto",
          source: "box-build",
          demand_class: class,
          inserted_at: DateTime.add(now, -i, :second),
          updated_at: DateTime.add(now, -i, :second)
        }
      end

    rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(Deployment, &1))
  end

  describe "the 24h BEFORE number, re-derived from the label" do
    setup do
      demo =
        for {slug, n} <- @demo_sites do
          site = site_fixture(slug)
          {:ok, site} = Registry.classify_site_demand(site, "platform")
          attempts(site, "platform", n)
          {slug, site, n}
        end

      # The customer remainder: 40 attempts spread over three real tenants.
      for {slug, n} <- [{"tenant-a", 20}, {"tenant-b", 13}, {"tenant-c", 7}] do
        site = site_fixture(slug)
        {:ok, site} = Registry.classify_site_demand(site, "customer")
        attempts(site, "customer", n)
      end

      # Six sites took ZERO in the window.
      for i <- 1..@zero_sites, do: site_fixture("idle-#{i}")

      %{demo: demo}
    end

    test "the attempt total is the measured 2,438" do
      c = DemandCensus.census(window_hours: 24)
      assert c.total == @window_total
      assert c.by_class["platform"] == @demo_total
      assert c.by_class["customer"] == @customer_total
      assert c.by_class["unclassified"] == 0
      assert c.by_class["unlabelled"] == 0

      # A PARTITION: the buckets sum to the total, so no attempt is counted
      # twice and none falls off the edge.
      assert c.by_class |> Map.values() |> Enum.sum() == c.total
    end

    test "the label re-derives the 98.4% concentration" do
      c = DemandCensus.census(window_hours: 24)

      assert c.classified_total == @window_total
      assert c.platform_share == 98.4
    end

    test "the rank-derived concentration, blind to the label, agrees" do
      c = DemandCensus.census(window_hours: 24, top_n: 5)

      assert c.top_site_share == 98.4
      assert c.top_site_share == c.platform_share

      assert Enum.map(c.top_sites, & &1.count) == [509, 491, 471, 468, 459]
      assert Enum.all?(c.top_sites, &(&1.demand_class == "platform"))

      # The five heaviest sites ARE the five demo sites — named, not assumed.
      slugs = Enum.map(c.top_sites, & &1.slug)

      for {expected, _n} <- @demo_sites do
        assert Enum.any?(slugs, &String.starts_with?(&1, expected)),
               "#{expected} is not among the five heaviest: #{inspect(slugs)}"
      end
    end

    test "six sites took zero" do
      assert DemandCensus.census(window_hours: 24).zero_sites == @zero_sites
    end

    test "the report line carries the numbers a task can paste" do
      text = DemandCensus.census(window_hours: 24) |> DemandCensus.report()

      assert text =~ "attempts=2438"
      assert text =~ "platform=2398(98.4%)"
      assert text =~ "platform_share=98.4"
      assert text =~ "top5=98.4%"
      assert text =~ "zero_sites=6"
    end

    test "a window that excludes the attempts reports zero, not the same 98.4%" do
      c = DemandCensus.census(since: ~U[2000-01-01 00:00:00Z], until: ~U[2000-01-02 00:00:00Z])

      assert c.total == 0
      assert c.platform_share == nil
      assert c.top_site_share == 0.0
    end
  end

  describe "the honest buckets" do
    test "an unclassified site's attempts are their own bucket, never customer" do
      site = site_fixture("unlabelled-demo")
      attempts(site, "unclassified", 9)

      c = DemandCensus.census(window_hours: 24)

      assert c.by_class["unclassified"] == 9
      assert c.by_class["customer"] == 0
      assert c.classified_total == 0

      # No classified rows means NO share, not a reassuring 0%.
      assert c.platform_share == nil
    end

    test "a pre-D206 NULL row is 'unlabelled', distinct from 'unclassified'" do
      site = site_fixture("legacy")
      attempts(site, nil, 4)
      attempts(site, "unclassified", 2)

      c = DemandCensus.census(window_hours: 24)

      assert c.by_class["unlabelled"] == 4
      assert c.by_class["unclassified"] == 2
    end

    test "a site reclassified mid-window is reported with no class, not one of its two" do
      site = site_fixture("switcher")
      attempts(site, "platform", 3)
      attempts(site, "customer", 2)

      c = DemandCensus.census(window_hours: 24, top_n: 1)

      assert [%{count: 5, demand_class: nil}] = c.top_sites
    end
  end

  describe "end to end through the writer" do
    test "the census counts what create_deployment stamped, not what a fixture wrote" do
      demo = site_fixture("demo-e2e")
      tenant = site_fixture("tenant-e2e")
      {:ok, demo} = Registry.classify_site_demand(demo, "platform")
      {:ok, tenant} = Registry.classify_site_demand(tenant, "customer")

      {:ok, _} = Registry.create_deployment(demo, %{trigger: "content-auto"})
      {:ok, _} = Registry.create_deployment(tenant, %{trigger: "content-auto"})

      c = DemandCensus.census(window_hours: 24)

      assert c.by_class["platform"] == 1
      assert c.by_class["customer"] == 1
      assert c.platform_share == 50.0
    end
  end
end
