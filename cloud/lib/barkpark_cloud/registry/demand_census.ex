defmodule BarkparkCloud.Registry.DemandCensus do
  @moduledoc """
  dr-w13-bl-demand-needs-a-label-before-a-cut (charter D206): the READER of
  `deployments.demand_class` — the instrument that has to exist BEFORE the
  amplifier is cut.

  ## The number this exists to hold

  A 24h window on the live control plane: 2,438 deployment attempts, of which
  2,398 (98.4%) landed on five demo sites — live-auto 509, search-capstone 491,
  astro-search 471, search-ember 468, search 459 — while six sites took ZERO.
  That measurement lives today as prose in a ledger row and SQL in a transcript.
  A cut made against a number no instrument can recompute is charter D3's
  vacuous green twice over: the rates improve, and nothing can tell an improved
  fleet from a smaller one.

  `census/1` is the recomputation. It is the BEFORE number's producer, so the
  same expression that reports today's concentration reports tomorrow's, and a
  regression is a diff rather than an argument.

  ## What it partitions on, and the third bucket

  `by_class` is a PARTITION of every attempt in the window — the counts sum to
  `total`, always:

    * `"customer"`     — minted on a site classified `customer`.
    * `"platform"`     — minted on a site classified `platform`: demo, fixture,
      capstone, internal. Self-inflicted churn.
    * `"unclassified"` — the writer ran, and the site carried NO class. Reported
      SEPARATELY and never folded into `"customer"`: an unlabelled demo site's
      churn counted as demand is the misreading this label exists to end.
    * `"unlabelled"`   — `demand_class IS NULL`: a row minted before the column
      existed. Distinct from `"unclassified"` on purpose — one says the label was
      never written, the other says it was written and had nothing to say.

  `platform_share` is therefore taken over CLASSIFIED rows only, and is `nil`
  when nothing in the window is classified. A share silently computed over a
  denominator of unlabelled rows would print a reassuring small number for a
  fleet nobody has measured.

  ## Concentration is measured INDEPENDENTLY of the label

  `top_sites` / `top_site_share` rank by attempt count and know nothing about
  `demand_class`. That is deliberate: it lets the two halves be compared. When
  the five heaviest sites are all classified `platform`, `platform_share` and
  `top_site_share` converge — and the label has re-derived the concentration
  rather than restated it. When they diverge, the classification is wrong, and
  that divergence is the only way a misclassification is ever visible.
  """

  import Ecto.Query

  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Registry.Site
  alias BarkparkCloud.Repo

  @default_window_hours 24
  @default_top_n 5

  @unlabelled "unlabelled"

  @type site_row :: %{
          site_id: binary(),
          slug: String.t() | nil,
          demand_class: String.t() | nil,
          count: non_neg_integer(),
          share: float()
        }

  @type t :: %{
          since: DateTime.t(),
          until: DateTime.t(),
          total: non_neg_integer(),
          by_class: %{String.t() => non_neg_integer()},
          class_share: %{String.t() => float()},
          classified_total: non_neg_integer(),
          platform_share: float() | nil,
          top_sites: [site_row()],
          top_site_share: float(),
          zero_sites: non_neg_integer()
        }

  @doc """
  The demand census over a window of deployment attempts.

  Options:

    * `:until`         — window end (default: now).
    * `:since`         — window start (default: `until` minus `:window_hours`).
    * `:window_hours`  — width when `:since` is not given (default 24).
    * `:top_n`         — how many sites the concentration arm names (default 5).

  Every count is over ATTEMPTS — deployment rows — not over builds that
  succeeded. The amplifier's cost is paid at attempt time (a slot taken, a
  deferral chain started), so an attempt is the unit a cut would remove.
  """
  @spec census(keyword()) :: t()
  def census(opts \\ []) do
    until = Keyword.get(opts, :until, DateTime.utc_now())

    since =
      Keyword.get_lazy(opts, :since, fn ->
        hours = Keyword.get(opts, :window_hours, @default_window_hours)
        DateTime.add(until, -hours * 3600, :second)
      end)

    top_n = Keyword.get(opts, :top_n, @default_top_n)

    by_class = class_counts(since, until)
    total = by_class |> Map.values() |> Enum.sum()

    classified_total = Map.get(by_class, "customer", 0) + Map.get(by_class, "platform", 0)

    per_site = site_counts(since, until)
    top_sites = per_site |> Enum.take(top_n) |> Enum.map(&put_share(&1, total))
    top_total = top_sites |> Enum.map(& &1.count) |> Enum.sum()

    %{
      since: since,
      until: until,
      total: total,
      by_class: by_class,
      class_share: Map.new(by_class, fn {k, n} -> {k, share(n, total)} end),
      classified_total: classified_total,
      platform_share:
        if(classified_total == 0,
          do: nil,
          else: share(Map.get(by_class, "platform", 0), classified_total)
        ),
      top_sites: top_sites,
      top_site_share: share(top_total, total),
      zero_sites: zero_site_count(since, until)
    }
  end

  @doc """
  One line per fact, for a human tailing a deploy or pasting evidence into a
  task. Never truncated and never rounded differently from `census/1` — the
  renderer reads the same map a reader would.
  """
  @spec report(t()) :: String.t()
  def report(%{} = c) do
    classes =
      c.by_class
      |> Enum.sort_by(fn {_k, n} -> -n end)
      |> Enum.map_join(" ", fn {k, n} -> "#{k}=#{n}(#{Map.fetch!(c.class_share, k)}%)" end)

    sites =
      Enum.map_join(c.top_sites, " ", fn s ->
        "#{s.slug || s.site_id}=#{s.count}[#{s.demand_class || @unlabelled}]"
      end)

    """
    demand_census window=#{DateTime.to_iso8601(c.since)}..#{DateTime.to_iso8601(c.until)}
    demand_census attempts=#{c.total} #{classes}
    demand_census classified=#{c.classified_total} platform_share=#{inspect(c.platform_share)}%
    demand_census top#{length(c.top_sites)}=#{c.top_site_share}% #{sites}
    demand_census zero_sites=#{c.zero_sites}
    """
  end

  defp class_counts(since, until) do
    base = %{"customer" => 0, "platform" => 0, "unclassified" => 0, @unlabelled => 0}

    from(d in Deployment,
      where: d.inserted_at >= ^since and d.inserted_at < ^until,
      group_by: d.demand_class,
      select: {d.demand_class, count(d.id)}
    )
    |> Repo.all()
    |> Enum.reduce(base, fn {class, n}, acc ->
      Map.update(acc, class || @unlabelled, n, &(&1 + n))
    end)
  end

  defp site_counts(since, until) do
    from(d in Deployment,
      left_join: s in Site,
      on: s.id == d.site_id,
      where: d.inserted_at >= ^since and d.inserted_at < ^until,
      group_by: [d.site_id, s.slug],
      select: {d.site_id, s.slug, count(d.id), max(d.demand_class), min(d.demand_class)}
    )
    |> Repo.all()
    |> Enum.map(fn {site_id, slug, n, max_class, min_class} ->
      # A site whose rows disagree is reported as `nil` rather than as one of
      # its two answers: it was RECLASSIFIED inside the window, and naming
      # either half would hide that the site changed sides mid-census.
      %{
        site_id: site_id,
        slug: slug,
        demand_class: if(max_class == min_class, do: max_class, else: nil),
        count: n
      }
    end)
    |> Enum.sort_by(fn r -> {-r.count, r.slug || r.site_id} end)
  end

  defp zero_site_count(since, until) do
    busy =
      from(d in Deployment,
        where: d.inserted_at >= ^since and d.inserted_at < ^until,
        select: d.site_id
      )

    from(s in Site, where: s.id not in subquery(busy), select: count(s.id))
    |> Repo.one()
  end

  defp put_share(row, total), do: Map.put(row, :share, share(row.count, total))

  defp share(_n, 0), do: 0.0
  defp share(n, total), do: Float.round(n * 100 / total, 1)
end
