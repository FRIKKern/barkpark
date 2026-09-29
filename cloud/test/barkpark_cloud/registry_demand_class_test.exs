defmodule BarkparkCloud.RegistryDemandClassTest do
  @moduledoc """
  dr-w13-bl-demand-needs-a-label-before-a-cut (charter D206): the DISCRIMINATOR
  half — `sites.demand_class` and the `deployments.demand_class` stamp.

  Proves, against the real Sandbox:

  * an unclassified site's build is stamped `"unclassified"` and NOT
    `"customer"` — the label admits it does not know, which is the only way it
    can ever lose;
  * the SAME code path stamps DIFFERENT values as the site's class changes, so
    the label is not a constant in disguise;
  * a reclassification does not rewrite the class of builds already minted;
  * the label CAN MISCLASSIFY: a demo site classified `"customer"` produces
    `"customer"` rows, and the census reports them as demand. The classification
    is data, and data can be wrong — a label that could not be wrong could not
    be checked either;
  * every create path stamps — `create_deployment/2`, `create_failed_deployment/3`
    and the preview fork `create_preview_deployment/4`;
  * the SIBLING-WRITER PREDICATE: nothing outside `registry.ex` builds a
    Deployment create changeset over a fresh struct, so a new writer cannot
    bypass the stamp without breaking this rule first.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.{Deployment, DemandCensus, Site}

  defp site_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  describe "the stamp" do
    test "an unclassified site's build is unclassified, NOT customer" do
      site = site_fixture()
      assert site.demand_class == nil

      {:ok, d} = Registry.create_deployment(site, %{trigger: "content-auto"})

      assert d.demand_class == "unclassified",
             "an unlabelled site's churn must not be counted as customer demand"
    end

    test "the same call stamps a DIFFERENT class as the site's class changes" do
      site = site_fixture()

      {:ok, site} = Registry.classify_site_demand(site, "platform")
      {:ok, churn} = Registry.create_deployment(site, %{trigger: "content-auto"})
      {:ok, churn} = Registry.transition_deployment(churn, %{status: "failed"})

      {:ok, site} = Registry.classify_site_demand(site, "customer")
      {:ok, demand} = Registry.create_deployment(site, %{trigger: "content-auto"})

      assert churn.demand_class == "platform"
      assert demand.demand_class == "customer"

      # The identical expression produced two different labels. A constant
      # cannot do that, and a read-time lookup against a hard-coded slug list
      # could not either.
      refute churn.demand_class == demand.demand_class
    end

    test "a reclassification does not rewrite the class of builds already minted" do
      site = site_fixture()
      {:ok, site} = Registry.classify_site_demand(site, "platform")
      {:ok, past} = Registry.create_deployment(site, %{trigger: "content-auto"})
      {:ok, _past} = Registry.transition_deployment(past, %{status: "failed"})

      {:ok, _site} = Registry.classify_site_demand(site, "customer")

      assert Repo.get!(Deployment, past.id).demand_class == "platform"
    end

    test "un-classifying a site is possible, and the next build says unclassified" do
      site = site_fixture()
      {:ok, site} = Registry.classify_site_demand(site, "platform")
      {:ok, site} = Registry.classify_site_demand(site, nil)

      assert site.demand_class == nil
      {:ok, d} = Registry.create_deployment(site, %{})
      assert d.demand_class == "unclassified"
    end

    test "create_failed_deployment stamps the class too" do
      site = site_fixture()
      {:ok, site} = Registry.classify_site_demand(site, "platform")

      {:ok, d} = Registry.create_failed_deployment(site, %{git_ref: "abc"}, "no repo linked")

      assert d.status == "failed"
      assert d.demand_class == "platform"
    end

    test "the preview fork stamps the class (a field cast only in changeset/2 is dropped here)" do
      site = site_fixture()
      {:ok, site} = Registry.classify_site_demand(site, "platform")

      {:ok, d} = Registry.create_preview_deployment(site, "feat/x", String.duplicate("a", 40))

      assert d.environment == "preview"
      assert d.demand_class == "platform"
    end
  end

  describe "the label can be WRONG, and that is the point" do
    test "a demo site classified customer produces customer rows the census believes" do
      demo = site_fixture()
      real = site_fixture()

      # The operator gets it BACKWARDS. Nothing in the code can tell: both sites
      # publish through the same content-auto path, on the same dataset, with
      # the same trigger/source pair.
      {:ok, demo} = Registry.classify_site_demand(demo, "customer")
      {:ok, real} = Registry.classify_site_demand(real, "platform")

      {:ok, churn} = Registry.create_deployment(demo, %{trigger: "content-auto"})
      {:ok, publish} = Registry.create_deployment(real, %{trigger: "content-auto"})

      assert churn.demand_class == "customer"
      assert publish.demand_class == "platform"

      before = DemandCensus.census(window_hours: 1)
      assert before.by_class["customer"] == 1
      assert before.by_class["platform"] == 1

      # Correcting the classification changes what the NEXT builds say — the
      # census is a function of the label, so a wrong label is a wrong census
      # and a corrected one is a corrected census.
      {:ok, demo} = Registry.classify_site_demand(demo, "platform")
      {:ok, real} = Registry.classify_site_demand(real, "customer")

      {:ok, c2} = Registry.transition_deployment(churn, %{status: "failed"})
      {:ok, _} = Registry.transition_deployment(publish, %{status: "failed"})
      assert c2.demand_class == "customer"

      {:ok, churn2} = Registry.create_deployment(demo, %{trigger: "content-auto"})
      {:ok, publish2} = Registry.create_deployment(real, %{trigger: "content-auto"})

      assert churn2.demand_class == "platform"
      assert publish2.demand_class == "customer"
    end
  end

  describe "the vocabulary is closed" do
    test "an unlisted site class is a validation error, not a silent bad row" do
      site = site_fixture()
      assert {:error, cs} = Registry.classify_site_demand(site, "demo-ish")
      assert %{demand_class: [_ | _]} = errors_on(cs)
    end

    test "an unlisted deployment class is a validation error" do
      site = site_fixture()

      cs = Deployment.changeset(%Deployment{}, %{site_id: site.id, demand_class: "vibes"})
      refute cs.valid?
      assert %{demand_class: [_ | _]} = errors_on(cs)
    end

    test "the two vocabularies differ by exactly the unclassified sentinel" do
      assert Site.demand_classes() == ~w(customer platform)
      assert Deployment.demand_classes() -- Site.demand_classes() == ["unclassified"]
    end
  end

  describe "the sibling-writer predicate" do
    test "only registry.ex builds a Deployment create changeset over a fresh struct" do
      # SHAPE-KEYED, not a list of known writers: the thing that mints a
      # deployment is `%Deployment{}` piped into one of the two create
      # changesets. `Deployment.changeset/2` over an ALREADY-PERSISTED row (the
      # artifact_sha256 stamp in sites/deploy.ex) is not a mint and must not
      # match. A new create path anywhere else reds this before it can ship an
      # unstamped row.
      pattern =
        ~r/%Deployment\{\}\s*(?:\r?\n\s*)?\|>\s*Deployment\.(?:changeset|preview_changeset)\(/

      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(fn path -> Regex.match?(pattern, File.read!(path)) end)

      assert offenders == ["lib/barkpark_cloud/registry.ex"],
             "a Deployment create changeset outside the stamping funnel: #{inspect(offenders)}"
    end
  end
end
