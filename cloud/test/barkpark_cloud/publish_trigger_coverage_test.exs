defmodule BarkparkCloud.PublishTriggerCoverageTest do
  @moduledoc """
  dr-w12-bl-site-publish-trigger-coverage.

  ## What this pins

  c0 — a QUERYABLE coverage predicate over content-bound sites, whose buckets
  PARTITION the population and in which the no-secret MINT GAP is its own named
  bucket (`mint_gap`, split into `:template_clock_only` and `:no_automation`),
  never folded into a generic "unregistered" count.

  c1 — a fixture that PRODUCES an unregistered content-bound site, so the coverage
  number can LOSE. The production is deliberately not a hand-nulled column: it
  runs the real Registry API twice —

      Registry.create_site/2       with a content-bound kind and NO dataset
                                   (`maybe_mint_content_secret/1` mints nothing)
      Registry.rebind_site_content/3  binds a dataset afterwards

  and `rebind_site_content/3` has no mint step, so the second call produces a
  LIVE content-bound site with a bound dataset and no content-publish secret.
  That is the mint gap, reproduced through doors an operator can reach today —
  the PATCH-rebind arm is a standing producer of the state this census counts,
  not merely a historical accident of a 2026-07-14 defect window.

  ## Scope

  Every read is scoped by `site_ids:` to this test's OWN fixture ids. The test
  database is shared across suites and partitions; an unscoped `coverage/1` would
  count another suite's rows and the assertions would be noise.

  ## No box, on purpose

  The `%Barkpark{}` fixture carries NO `url`, so `create_site/2`'s best-effort
  webhook registration and `mint_content_publish_secret/2`'s post-mint
  registration both short-circuit to `:noop` without an HTTP client. This suite
  is about the ROW-derived census; the box half is the reconciler's suite.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.PublishTriggerCoverage, as: Coverage
  alias BarkparkCloud.Registry.Site

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  # A box with NO url — see the moduledoc: every box call short-circuits.
  defp bp_fixture do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team_fixture(), %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
  end

  # THE COVERED SITE. `create_site/2` with a content-bound kind AND a dataset
  # mints the content-publish secret on the row.
  defp webhook_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_read_#{n}"
      })

    site
  end

  # THE c1 PRODUCER. Two real Registry calls, no hand-written column:
  # create datasetless (nothing to mint) → rebind onto a dataset (no mint step).
  # The result is a content-bound site with a bound dataset and NO secret.
  defp unregistered_content_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, unbound} =
      Registry.create_site(bp, %{
        name: "Rebound #{n}",
        slug: "rebound-#{n}",
        kind: "static",
        framework: "astro",
        read_token: "bpt_read_#{n}"
      })

    # Nothing was minted, precisely because there was no dataset to bind.
    assert is_nil(unbound.content_webhook_secret_encrypted)
    assert Registry.publish_trigger(unbound) == :not_applicable

    {:ok, rebound, :none} =
      Registry.rebind_site_content(
        unbound,
        %{
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_read_#{n}_rebound",
          content_binding_verdict: "bound"
        },
        :absent
      )

    rebound
  end

  defp container_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "App #{n}",
        slug: "app-#{n}",
        kind: "container",
        framework: "nextjs"
      })

    site
  end

  defp unbound_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Naked #{n}",
        slug: "naked-#{n}",
        kind: "static",
        framework: "astro",
        read_token: "bpt_read_#{n}"
      })

    site
  end

  # Put the site in the hourly TemplateFreshnessWorker's population: a current
  # deployment pointer. That is the ONLY thing `list_deployed_content_sites/0`
  # adds over the content-bound predicate.
  defp deployed(%Site{} = site) do
    {:ok, deployment} = Registry.create_deployment(site, %{trigger: "manual"})

    site
    |> Ecto.Changeset.change(current_deployment_id: deployment.id)
    |> Repo.update!()
  end

  defp ids(sites), do: Enum.map(sites, & &1.id)

  ## c0 — the partition

  describe "c0: the buckets partition the population" do
    test "one site per bucket, and the five counts sum to what was examined" do
      bp = bp_fixture()

      covered = webhook_site(bp)
      clock_only = bp |> unregistered_content_site() |> deployed()
      no_automation = unregistered_content_site(bp)
      container = container_site(bp)
      unbound = unbound_site(bp)

      all = [covered, clock_only, no_automation, container, unbound]
      rows = Coverage.rows(site_ids: ids(all))
      by_id = Map.new(rows, &{&1.site_id, &1})

      assert by_id[covered.id].bucket == :content_webhook
      assert by_id[clock_only.id].bucket == :template_clock_only
      assert by_id[no_automation.id].bucket == :no_automation
      assert by_id[container.id].bucket == :outside_container
      assert by_id[unbound.id].bucket == :outside_unbound

      # Every bucket the module declares was reachable by this fixture — a
      # partition nobody can land in is not a partition.
      assert Enum.sort(Enum.map(rows, & &1.bucket)) == Enum.sort(Coverage.buckets())

      tally = Coverage.coverage(site_ids: ids(all))
      assert tally.examined == 5
      assert tally.buckets |> Map.values() |> Enum.sum() == tally.examined
      assert Map.keys(tally.buckets) |> Enum.sort() == Enum.sort(Coverage.buckets())
    end

    test "the denominator excludes the container and the unbound site" do
      bp = bp_fixture()
      covered = webhook_site(bp)
      container = container_site(bp)
      unbound = unbound_site(bp)

      tally = Coverage.coverage(site_ids: ids([covered, container, unbound]))

      # Three rows examined, ONE owed a publish trigger. Folding the two outside
      # rows into the denominator is exactly how a 5-of-12 fleet gets published
      # as 5-of-13.
      assert tally.examined == 3
      assert tally.content_bound == 1
      assert tally.covered == 1
      assert tally.mint_gap == 0
    end

    test "per-site rows carry the publish_trigger they were derived from" do
      bp = bp_fixture()
      covered = webhook_site(bp)
      gap = unregistered_content_site(bp)
      container = container_site(bp)

      rows = Coverage.rows(site_ids: ids([covered, gap, container]))
      by_id = Map.new(rows, &{&1.site_id, &1})

      assert by_id[covered.id].publish_trigger == :present
      assert by_id[covered.id].covered?
      assert by_id[covered.id].content_bound?

      assert by_id[gap.id].publish_trigger == :absent
      refute by_id[gap.id].covered?
      assert by_id[gap.id].content_bound?

      assert by_id[container.id].publish_trigger == :not_applicable
      refute by_id[container.id].covered?
      refute by_id[container.id].content_bound?
    end
  end

  ## c0 — the mint gap is its OWN bucket

  describe "c0: the mint gap is a named bucket, never folded into 'unregistered'" do
    test "mint_gap is its own key and is the sum of exactly the two no-secret buckets" do
      bp = bp_fixture()
      covered = webhook_site(bp)
      clock_only = bp |> unregistered_content_site() |> deployed()
      no_automation = unregistered_content_site(bp)
      all = [covered, clock_only, no_automation]

      tally = Coverage.coverage(site_ids: ids(all))

      assert tally.mint_gap == 2
      assert tally.buckets.template_clock_only == 1
      assert tally.buckets.no_automation == 1
      assert Coverage.mint_gap_buckets() == [:template_clock_only, :no_automation]

      # The arithmetic that makes the census meaningful.
      assert tally.covered + tally.mint_gap == tally.content_bound
    end

    test "the mint-gap buckets ARE Registry.list_sites_missing_content_secret/1's population" do
      bp = bp_fixture()
      covered = webhook_site(bp)
      clock_only = bp |> unregistered_content_site() |> deployed()
      no_automation = unregistered_content_site(bp)
      container = container_site(bp)
      unbound = unbound_site(bp)
      all = [covered, clock_only, no_automation, container, unbound]
      fixture_ids = MapSet.new(ids(all))

      census_gap =
        Coverage.rows(site_ids: ids(all))
        |> Enum.filter(&(&1.bucket in Coverage.mint_gap_buckets()))
        |> Enum.map(& &1.site_id)
        |> MapSet.new()

      # The shared test DB holds other suites' rows, so the reference list is
      # narrowed to THIS fixture's ids before the sets are compared.
      registry_gap =
        Registry.list_sites_missing_content_secret(500)
        |> Enum.map(& &1.id)
        |> Enum.filter(&MapSet.member?(fixture_ids, &1))
        |> MapSet.new()

      assert census_gap == MapSet.new([clock_only.id, no_automation.id])
      assert census_gap == registry_gap
    end

    test "a template-clock-only site is NOT covered — a code roll is not a content publish" do
      bp = bp_fixture()
      clock_only = bp |> unregistered_content_site() |> deployed()

      refute Coverage.covered?(clock_only)
      assert Coverage.content_bound?(clock_only)
      assert Coverage.bucket(clock_only) == :template_clock_only

      tally = Coverage.coverage(site_ids: [clock_only.id])
      assert tally.content_bound == 1
      assert tally.covered == 0
      assert tally.mint_gap == 1
    end
  end

  ## c1 — the number can LOSE

  describe "c1: a fixture produces an unregistered content-bound site" do
    test "create_site + rebind_site_content yields a bound site with NO secret" do
      bp = bp_fixture()
      site = unregistered_content_site(bp)

      # Produced through the real API, not by nulling a column.
      assert site.kind == "static"
      assert site.bootstrap_dataset == "production"
      assert is_nil(site.content_webhook_secret_encrypted)
      assert Registry.publish_trigger(site) == :absent
      assert Coverage.bucket(site) in Coverage.mint_gap_buckets()
    end

    test "the coverage number LOSES when the unregistered site is in scope" do
      bp = bp_fixture()
      covered = webhook_site(bp)
      gap = unregistered_content_site(bp)

      # The control: the covered site ALONE is a full house. If this arm were
      # also short, the losing arm below would prove nothing about the gap site.
      full = Coverage.coverage(site_ids: [covered.id])
      assert full.content_bound == 1
      assert full.covered == 1
      assert full.mint_gap == 0

      lost = Coverage.coverage(site_ids: ids([covered, gap]))
      assert lost.content_bound == 2
      assert lost.covered == 1
      assert lost.mint_gap == 1
      assert lost.covered < lost.content_bound
    end

    test "the operator mint verb moves the site OUT of the gap and the number back to full" do
      bp = bp_fixture()
      gap = unregistered_content_site(bp)

      before = Coverage.coverage(site_ids: [gap.id])
      assert before.covered == 0
      assert before.mint_gap == 1

      # `mint_content_publish_secret/2` is the ONLY door that repairs this state —
      # the hourly reconciler reveals a secret and never mints one, so it is a
      # :noop here forever. Registration is `:noop` because the fixture box has
      # no url.
      assert {:ok, minted, :noop} = Registry.mint_content_publish_secret(gap)
      assert Coverage.bucket(minted) == :content_webhook

      after_mint = Coverage.coverage(site_ids: [gap.id])
      assert after_mint.covered == 1
      assert after_mint.mint_gap == 0
      assert after_mint.content_bound == 1
    end

    test "the hourly reconciler's population does NOT contain the gap site" do
      bp = bp_fixture()
      covered = webhook_site(bp)
      gap = unregistered_content_site(bp)
      fixture_ids = MapSet.new(ids([covered, gap]))

      swept =
        Registry.list_content_webhook_sites(500)
        |> Enum.map(& &1.id)
        |> Enum.filter(&MapSet.member?(fixture_ids, &1))
        |> MapSet.new()

      # The whole reason the gap is its own bucket: the sweep that repairs an
      # unregistered site cannot even SEE this one.
      assert swept == MapSet.new([covered.id])
    end
  end

  ## The copied predicates, pinned against their sources

  describe "the copies agree with Registry" do
    test "@content_bound_kinds still matches what publish_trigger/1 rules content-bound" do
      # `~w(container static node)` is Site's own @kinds list (site.ex:43).
      assert Coverage.agrees_with_registry(~w(container static node)) == {:ok, ~w(static node)}
    end

    test "template_clock_reaches? agrees with Registry.list_deployed_content_sites/0" do
      bp = bp_fixture()
      deployed_gap = bp |> unregistered_content_site() |> deployed()
      undeployed_gap = unregistered_content_site(bp)
      deployed_covered = bp |> webhook_site() |> deployed()
      container = bp |> container_site() |> deployed()
      all = [deployed_gap, undeployed_gap, deployed_covered, container]
      fixture_ids = MapSet.new(ids(all))

      registry_population =
        Registry.list_deployed_content_sites()
        |> Enum.map(& &1.id)
        |> Enum.filter(&MapSet.member?(fixture_ids, &1))
        |> MapSet.new()

      # The census's own answer to "does the hourly clock reach it", read off the
      # buckets: `:template_clock_only` plus every deployed `:content_webhook`.
      census_population =
        Coverage.rows(site_ids: ids(all))
        |> Enum.filter(&(&1.bucket in [:template_clock_only, :content_webhook]))
        |> Enum.map(& &1.site_id)
        |> MapSet.new()

      assert registry_population == MapSet.new([deployed_gap.id, deployed_covered.id])
      assert census_population == registry_population

      # The control that makes the equality mean something: a deployed CONTAINER
      # is in neither, so the sets do not agree merely by counting deployments.
      refute MapSet.member?(registry_population, container.id)
      refute MapSet.member?(census_population, container.id)
    end
  end

  ## Scoping

  describe "scoping" do
    test "barkpark_id scopes the census to one box" do
      bp_a = bp_fixture()
      bp_b = bp_fixture()
      a_covered = webhook_site(bp_a)
      _a_gap = unregistered_content_site(bp_a)
      b_covered = webhook_site(bp_b)

      tally = Coverage.coverage(barkpark_id: bp_a.id)
      assert tally.content_bound == 2
      assert tally.covered == 1
      assert tally.mint_gap == 1

      assert Coverage.rows(barkpark_id: bp_b.id) |> Enum.map(& &1.site_id) == [
               b_covered.id
             ]

      refute a_covered.id in Enum.map(Coverage.rows(barkpark_id: bp_b.id), & &1.site_id)
    end
  end
end
