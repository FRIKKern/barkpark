defmodule BarkparkCloud.Registry.PublishTriggerCoverage do
  @moduledoc """
  dr-w12-bl-site-publish-trigger-coverage: the QUERYABLE half of "does this site
  have a publish trigger" — a bucketed census over a scoped population of sites,
  built on `Registry.publish_trigger/1`.

  ## What already existed, and what did not

  `Registry.publish_trigger/1` answers the question for ONE loaded `%Site{}` and
  is rendered per-site by `GET /v1/sites` and `Sites.Doctor`. Nothing aggregated
  it. There was no way to ask "of the content-bound sites on this box, how many
  can a content publish actually reach, and what is wrong with the rest" without
  loading every row and folding by hand — so the fleet's honest coverage figure
  had no producer and no reader.

  This module is that producer. It is DERIVED and never stored, for the same
  reason `publish_trigger/1` is: the truth lives on the box, and a stamped column
  goes stale the moment someone deletes a webhook by hand.

  ## The buckets — a PARTITION of the scoped population

  Every site lands in exactly one, and the three content-bound buckets sum to the
  denominator:

    * `:content_webhook` — `publish_trigger/1` is `:present`. A content publish on
      the bound dataset reaches this site's per-site receiver. THE ONLY COVERED
      BUCKET.
    * `:template_clock_only` — `publish_trigger/1` is `:absent`, and the site is
      in the hourly `Sites.TemplateFreshnessWorker` population (it has a current
      deployment). Something deploys it, but only on a CODE roll: a content
      publish still reaches nothing.
    * `:no_automation` — `publish_trigger/1` is `:absent` and the site was never
      deployed, so not even the hourly clock visits it. Nothing auto-deploys it
      at all.
    * `:outside_container` — `kind` is not content-bound (`container`). It builds
      from a repo and is owed no content-publish trigger; it is NOT in the
      denominator, and counting it there is how a 5-of-12 fleet gets reported as
      5-of-13.
    * `:outside_unbound` — a content-bound KIND with no bound dataset. Same
      verdict, different reason, and kept separate because the remedies differ:
      a container is structurally outside forever, an unbound static site becomes
      part of the denominator the moment someone binds it.

  ## WHY THE MINT GAP IS ITS OWN NAMED BUCKET

  `:template_clock_only` and `:no_automation` are the two halves of the MINT GAP
  (`mint_gap` on the tally, and exactly the population
  `Registry.list_sites_missing_content_secret/1` returns). It must never be folded
  into a generic "unregistered" number, because "unregistered" mixes two states
  with OPPOSITE repair costs:

    * a site that HAS a secret and is merely missing its box webhook row is
      repaired by the hourly `ContentWebhookReconciler` on its next tick, with no
      human in the loop;
    * a site with NO secret is a `:noop` for that sweep FOREVER —
      `ensure_content_webhook/2` REVEALS a secret and never MINTS one, so the
      reconciler structurally cannot reach it. Its only repair is the operator
      verb `Registry.mint_content_publish_secret/2`.

  One number covering both says "N sites are unregistered" and implies the
  schedule will handle it. For the mint-gap half that is false, and it was false
  for six of guerrilla's thirteen sites for twenty-four days.

  ## THE HONEST BOUND

  Inherited from `publish_trigger/1` and restated because a coverage number that
  overclaims is worse than none: `:content_webhook` says a site is CONFIGURED to
  receive content-publish triggers, not that the webhook row is live on the box
  this second. Confirming that costs a cross-host call per site. The hourly
  reconciler is what keeps `:content_webhook` true.

  ## Scope is MANDATORY-ISH by design

  `rows/1` and `coverage/1` take a scope (`:site_ids`, `:barkpark_id`,
  `:team_id`) and a `:limit`. An unscoped call reads the whole fleet, which is the
  operator question; a scoped call is what a per-box surface and every test wants.
  """

  import Ecto.Query

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Repo

  # COPIED, not imported: `@content_bound_kinds` is a private attribute of
  # `BarkparkCloud.Registry` (registry.ex:252, `~w(static node)`), and that module
  # is under an open change this file must not touch. `agrees_with_registry/0` and
  # the "pins the copy" test hold the two in agreement by comparing THIS list
  # against what `Registry.publish_trigger/1` actually rules `:not_applicable`, so
  # a widening of the real list reds here instead of drifting silently.
  @content_bound_kinds ~w(static node)

  @buckets [
    :content_webhook,
    :template_clock_only,
    :no_automation,
    :outside_container,
    :outside_unbound
  ]

  @mint_gap_buckets [:template_clock_only, :no_automation]

  @default_limit 500

  @type bucket ::
          :content_webhook
          | :template_clock_only
          | :no_automation
          | :outside_container
          | :outside_unbound

  @type row :: %{
          site_id: binary(),
          slug: binary(),
          kind: binary(),
          publish_trigger: :present | :absent | :not_applicable,
          bucket: bucket(),
          content_bound?: boolean(),
          covered?: boolean()
        }

  @doc "The five buckets, in report order. The list IS the partition."
  @spec buckets() :: [bucket()]
  def buckets, do: @buckets

  @doc """
  The two buckets that together are THE MINT GAP — content-bound sites with no
  content-publish secret, which the hourly reconciler structurally cannot repair.
  """
  @spec mint_gap_buckets() :: [bucket()]
  def mint_gap_buckets, do: @mint_gap_buckets

  @doc """
  Which bucket does this site fall in? Reads the Site row alone — no box call.

  The content-bound split is delegated to `Registry.publish_trigger/1` so there is
  exactly ONE definition of "has a publish trigger" in the plane; this function
  only says WHY a site has none, and whether it was owed one.
  """
  @spec bucket(Site.t()) :: bucket()
  def bucket(%Site{} = site) do
    case Registry.publish_trigger(site) do
      :present ->
        :content_webhook

      :absent ->
        if template_clock_reaches?(site), do: :template_clock_only, else: :no_automation

      :not_applicable ->
        if site.kind in @content_bound_kinds, do: :outside_unbound, else: :outside_container
    end
  end

  @doc """
  Can a CONTENT PUBLISH reach this site? True only for `:content_webhook`.

  A `:template_clock_only` site is deliberately NOT covered: the hourly sweep
  redeploys it when the box's code revision moves, which is a different event
  from a human publishing a document. Counting it would restore the exact false
  green this census exists to remove.
  """
  @spec covered?(Site.t()) :: boolean()
  def covered?(%Site{} = site), do: bucket(site) == :content_webhook

  @doc """
  Is this site owed a publish trigger at all — i.e. is it in the denominator?
  """
  @spec content_bound?(Site.t()) :: boolean()
  def content_bound?(%Site{} = site),
    do: bucket(site) not in [:outside_container, :outside_unbound]

  @doc """
  One row per site in scope, oldest-first.

  `opts`:

    * `:site_ids` — restrict to these ids (what a test scopes with; the test
      database is shared and an unscoped count would read other suites' rows),
    * `:barkpark_id` — one box's sites,
    * `:team_id` — one team's sites,
    * `:limit` — bound (default `#{@default_limit}`).
  """
  @spec rows(keyword()) :: [row()]
  def rows(opts \\ []) do
    opts |> scoped_sites() |> Enum.map(&row/1)
  end

  @doc """
  The tally over the same scope: the five buckets, the denominator, the covered
  count, and `mint_gap` as ITS OWN key.

  `covered + mint_gap == content_bound`, and the five bucket counts sum to
  `examined` — both are asserted by the suite, because a census whose buckets do
  not partition its population is a number with no meaning.
  """
  @spec coverage(keyword()) :: %{
          examined: non_neg_integer(),
          content_bound: non_neg_integer(),
          covered: non_neg_integer(),
          mint_gap: non_neg_integer(),
          buckets: %{bucket() => non_neg_integer()}
        }
  def coverage(opts \\ []) do
    rows = rows(opts)
    zero = Map.new(@buckets, &{&1, 0})
    counts = Enum.reduce(rows, zero, fn r, acc -> Map.update!(acc, r.bucket, &(&1 + 1)) end)
    mint_gap = @mint_gap_buckets |> Enum.map(&Map.fetch!(counts, &1)) |> Enum.sum()

    %{
      examined: length(rows),
      content_bound: counts.content_webhook + mint_gap,
      covered: counts.content_webhook,
      mint_gap: mint_gap,
      buckets: counts
    }
  end

  @doc """
  Does the copied `@content_bound_kinds` list still agree with the live rule in
  `Registry.publish_trigger/1`?

  Returns `{:ok, kinds}` or `{:error, %{unexpected_bound: [...], unexpected_unbound: [...]}}`.
  It probes with in-memory `%Site{}` structs — no database, no writes — asking
  `publish_trigger/1` itself which kinds it declines to rule `:not_applicable`
  when a dataset IS bound. The suite calls this so a widening of the real private
  list (as `static` → `static | node` already was once) reds HERE rather than
  quietly re-splitting `:outside_container` and `:outside_unbound` wrongly.
  """
  @spec agrees_with_registry([binary()]) :: {:ok, [binary()]} | {:error, map()}
  def agrees_with_registry(all_kinds) when is_list(all_kinds) do
    bound =
      Enum.filter(all_kinds, fn kind ->
        Registry.publish_trigger(%Site{
          kind: kind,
          bootstrap_dataset: "production",
          content_webhook_secret_encrypted: "x"
        }) != :not_applicable
      end)

    unexpected_bound = bound -- @content_bound_kinds
    unexpected_unbound = Enum.filter(@content_bound_kinds, &(&1 not in bound))

    if unexpected_bound == [] and unexpected_unbound == [] do
      {:ok, @content_bound_kinds}
    else
      {:error, %{unexpected_bound: unexpected_bound, unexpected_unbound: unexpected_unbound}}
    end
  end

  ## Internals

  defp row(%Site{} = site) do
    b = bucket(site)

    %{
      site_id: site.id,
      slug: site.slug,
      kind: site.kind,
      publish_trigger: Registry.publish_trigger(site),
      bucket: b,
      content_bound?: b not in [:outside_container, :outside_unbound],
      covered?: b == :content_webhook
    }
  end

  # The hourly template clock's population, restricted to ONE site. COPIED from
  # `Registry.list_deployed_content_sites/0` (registry.ex:7168) — the query
  # `Sites.TemplateFreshnessWorker` sweeps — because that is a fleet-wide
  # `Repo.all` and this must be a pure per-row predicate. Kept total (all three
  # conditions, not just the deployment pointer) so the copy can be pinned
  # against the real query by the suite rather than trusted.
  defp template_clock_reaches?(%Site{} = site) do
    site.kind in @content_bound_kinds and
      not is_nil(site.current_deployment_id) and
      is_binary(site.bootstrap_dataset) and site.bootstrap_dataset != ""
  end

  defp scoped_sites(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Site
    |> scope_ids(Keyword.get(opts, :site_ids))
    |> scope_eq(:barkpark_id, Keyword.get(opts, :barkpark_id))
    |> scope_eq(:team_id, Keyword.get(opts, :team_id))
    |> order_by([s], asc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp scope_ids(query, nil), do: query
  defp scope_ids(query, ids) when is_list(ids), do: where(query, [s], s.id in ^ids)

  defp scope_eq(query, _field, nil), do: query
  defp scope_eq(query, :barkpark_id, id), do: where(query, [s], s.barkpark_id == ^id)
  defp scope_eq(query, :team_id, id), do: where(query, [s], s.team_id == ^id)
end
