defmodule BarkparkCloud.Repo.Migrations.AddDemandClassToSitesAndDeployments do
  @moduledoc """
  dr-w13-bl-demand-needs-a-label-before-a-cut (charter D206): THE LABEL LANDS
  BEFORE THE CUT.

  ## What the deploy stream cannot say today

  `deployments.trigger` / `deployments.source` is 99.06% ONE label pair —
  `content-auto` / `box-build` covers 2,415 of 2,438 rows. Both columns answer
  provenance questions that are already settled for nearly every row: WHO asked
  (a content publish) and WHO BUILT (the box). Neither answers the question a
  demand cut turns on — was this build asked for by a CUSTOMER, or is it the
  demo fleet churning against itself?

  98.4% of a 24h window's attempts land on five demo sites (live-auto 509,
  search-capstone 491, astro-search 471, search-ember 468, search 459 — 2,398 of
  2,438), and six sites took ZERO. Cutting the amplifier would move every
  published rate at once, and NO instrument could say whether the fleet got
  better or the load merely got smaller. That is charter D3's vacuous green.

  ## Two columns, because a class is a fact about a SITE and a fact about a BUILD

    * `sites.demand_class` — the site's standing classification: "customer" (a
      real tenant whose publishes are demand we exist to serve) or "platform"
      (a demo / fixture / internal site whose publishes are churn we produce
      ourselves). NULL means NOBODY HAS CLASSIFIED IT, which is the honest
      reading and is deliberately NOT the same as "customer".

    * `deployments.demand_class` — the class AS OF THE MOMENT THE BUILD WAS
      MINTED, stamped by `Registry.create_deployment/2` and its two siblings.
      It is a create-time provenance field exactly like `trigger` and `source`,
      and it lives on the deployment row for the same reason those do: a site
      can be reclassified (a demo site promoted to a customer, a customer site
      retired into the fixture fleet) and a census over historical load must
      not have its past rewritten by today's classification. Reading the class
      through a JOIN at census time would make every BEFORE number a function
      of the present.

  ## Why there is no hard-coded demo-site list anywhere in this change

  A label derived at read time from a list of five slugs is a CONSTANT wearing a
  column's clothes: it can never disagree with the list, so no fixture can make
  it lose and no regression can make it red. The class is DATA — written per
  site through `Registry.classify_site_demand/2` — precisely so it can be wrong,
  can be changed, and can be measured against.

  ## No backfill, and the absence of one is the point

  Every existing row stays NULL. A backfill would claim a classification nobody
  made; worse, backfilling the five demo slugs would re-introduce the hard-coded
  list as a one-off write and make the first census a tautology. The BEFORE
  number this label exists to produce is measured by
  `Registry.DemandCensus.census/1` over rows the writers stamp.

  ## Why this ALTER is safe on the live tables

  Both columns are nullable with NO default, so this is a catalog-only `ALTER`:
  no table rewrite, no per-row work, the ACCESS EXCLUSIVE lock held for a
  catalog update rather than a scan. Same argument as
  `20260910140000_add_deferral_pacing_to_deployments` and
  `20260910120000_add_grace_counters_to_deployments` on this same table.

  No index. `DemandCensus.census/1` scans the same pinned `inserted_at` window
  the deploy ledger already scans, and an index with no reader is write cost for
  nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:sites) do
      add :demand_class, :string
    end

    alter table(:deployments) do
      add :demand_class, :string
    end
  end
end
