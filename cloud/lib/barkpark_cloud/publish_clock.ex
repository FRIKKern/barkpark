defmodule BarkparkCloud.PublishClock do
  @moduledoc """
  The publish→web clock: how long a human's publish waited before the bytes it
  produced were actually live — measured from the instant the control plane
  VERIFIED the delivery, not from the instant it enqueued a build.

  deploy-reliability W12 S2 (charter D176). Wave 11 built the half that WRITES
  the true t0 (`BarkparkCloud.Registry.ContentPublish` / `content_publishes`,
  migration applied on cloud-db-1 at 2026-08-07 08:10:38Z). That module exposes
  `record/3`, `mark_enqueued/2` and `enqueued?/1` — three writers and ZERO
  readers. This is the reader.

  ## The join rule, and why the obvious one is wrong

  The obvious rule — "the nearest forward `deployments.inserted_at`" — was
  measured against the live corpus and it picks a DEFERRED row for 17 of 20
  recorded deliveries, and all 17 of those rows never went live. A clock built
  on it would report the wait until a build that never served a byte. So, per
  publish `p`:

      LEFT JOIN LATERAL (
        SELECT dd.id, dd.became_live_at FROM deployments dd
        WHERE dd.site_id = p.site_id
          AND dd.became_live_at IS NOT NULL
          AND dd.became_live_at >= p.received_at   -- SEEK BOUND ONLY (see below)
          AND dd.inserted_at    >= p.received_at   -- the honesty guard
        ORDER BY dd.became_live_at LIMIT 1) d ON TRUE

  `inserted_at >= received_at` is the ANTI-OVER-CREDITING GUARD, and it is the
  semantic half of this rule. Without it, a build that was ALREADY IN FLIGHT
  when the publish arrived gets credited with serving that publish — it cannot
  have, because it was assembled from bytes that predate it. The guard is
  deliberately conservative: it can only ever UNDER-credit (a publish whose
  content genuinely rode an in-flight build is charged the wait to the NEXT
  build instead). Measured on the live corpus it moves exactly ONE of twenty
  rows — from 10.0s to 214.3s, 21x. It is not decoration; `publish_clock_test`
  pins both numbers against an unguarded control query.

  `became_live_at >= received_at` is LOGICALLY IMPLIED by the guard and exists
  PURELY as an index seek predicate — it is a performance predicate, never a
  semantic one. It is provably free: `select count(*) from deployments where
  became_live_at < inserted_at` is 0 over 30,648 live rows, i.e. no deployment
  has ever gone live before it was inserted, so a row the seek bound excludes is
  a row the guard would have excluded anyway. Measured worth on the 7d census:
  `Buffers: shared hit=37614 / 39.781 ms / Rows Removed by Filter: 1999`
  WITHOUT it against `hit=55 / 0.386 ms / Removed: 0` WITH it — 684x fewer
  buffers for the same answer. The premise is not assumed: `seek_bound/0` counts
  the violations, `census/3` runs it by default and reports it, and the moment
  that count leaves zero the census says so instead of quietly changing meaning.

  The index the bound seeks (`deployments_site_became_live_index` on
  `(site_id, became_live_at) WHERE became_live_at IS NOT NULL`) is already
  declared by migration `20260807140000` and already on prod. This module adds
  no index.

  ## FOUR named buckets, never one

  A publish with no matching deployment is not one thing, and folding the four
  into a single "missed" number is how an instrument lies:

    * `delivered` — a lateral row exists. THE ONLY bucket that contributes to a
      percentile.
    * `waiting_censored` — no match yet, and the delivery is NEWER than the
      horizon. RIGHT-CENSORED: its true wait is unknown and can only be reported
      as `>= now - received_at`. Never folded into a percentile — a censored row
      pushed into p50 as if it had landed is how a fleet reports a median it has
      not earned.
    * `never_delivered` — no match, OLDER than the horizon, and the site did go
      live in this window. This is the real finding: the site was deploying,
      just not for this publish.
    * `site_never_live` — no match, older than the horizon, and the site has no
      live deployment in the window at all.

  `site_never_live` IS SHIPPED BUT IS STRUCTURALLY UNREACHABLE THROUGH THIS
  RECORDER, and it is labelled that way in the output (`structurally_unreachable:
  true`) rather than presented as a live bucket. `ContentPublish.record/3` is
  called on exactly one arm — the HMAC-verified content-webhook receiver — so the
  population of `content_publishes` is exactly the webhook-bound sites, all of
  which go live. A reader who treats this bucket's constant zero as evidence of
  health is reading a bucket that cannot fill. It exists so that a FUTURE
  recorder (a manual trigger, a backfill — the `source` column is there for
  exactly this) cannot silently land in `never_delivered` and be read as a
  delivery failure by a site that never deploys at all.

  ## The denominator is DELIVERIES, not publishes

  `content_publishes` counts DELIVERIES. One human publish fans out to one
  delivery per webhook-bound site: the first 20 rows on prod were four bursts of
  exactly five, crediting only 14 distinct deployments. The join is therefore
  N:1 BY CONSTRUCTION, and this module does not dedupe — each delivery's own
  wait is real, and a site that is slow on the same publish everyone else served
  fast is precisely the finding worth having. But the count must never be
  printed as "publishes": `denominator_label` is `"deliveries"`, the key is
  `:deliveries`, there is no `:publishes` key to grab by accident, and the census
  reports `matched_deployments` beside it so the N:1 shape is visible
  (`delivered >= matched_deployments`, asserted in the test).

  ## Correct on an EMPTY table — the censor line, not a comforting zero

  With no rows, the honest answer is not "0 seconds" and not "0%". It is a
  CENSOR LINE: how many live deploys the window held, that none of them carry a
  recorded delivery, and SINCE WHEN the recorder has been running — because
  before that instant the population is censored, not empty.

  The censor date is read from the MIGRATION INSTANT (`select inserted_at from
  schema_migrations where version = 20260807130000`), NEVER from
  `min(received_at)`. Quoting `min(received_at)` mistakes "no publishes yet" for
  "recorder not yet running", and on the day this was measured the two differed
  by 4.8 minutes — a window that looks fully covered and is not. When
  `schema_migrations` carries no such row, `recorder_live_since` is `nil` and the
  line says the start is UNKNOWN; it does not fall back to the data.

  ## Retention: accepted unbounded growth, with a named revisit trigger

  Measured rate: 134 production paper publishes per 24h x 5 webhook-bound sites
  ≈ **670 rows/day** (~245k/yr) at 96 bytes/row heap — roughly 24 MB/yr including
  the `(site_id, received_at)` index. That is accepted as unbounded growth: the
  table is append-only, and a year of it is smaller than one day of
  `deployments`. REVISIT TRIGGER, stated so it is not a vibe: partition by month
  once the sustained rate exceeds ~50k rows/day (75x today), or once the census
  window scan leaves single-digit milliseconds. Do NOT re-derive the rate from a
  burst window — the 21-minute sample that produced the first 20 rows
  extrapolates to 1,339/day, double the truth.

  ## Readership caveat

  This is QUERYABLE LAW BEFORE IT IS A VISIBLE SURFACE. Every operator read path
  in the control plane is behind `require_platform_operator`, and
  `PLATFORM_ADMIN_EMAILS` is unset on prod (charter D165) — so nothing a human
  can reach today calls this module. Surfacing it is filed separately, and this
  module deliberately returns a map (never rendered prose) so the surface, when
  it lands, cannot change the numbers.
  """

  alias BarkparkCloud.Repo

  # The migration that created `content_publishes`. The recorder cannot have
  # observed anything before this row was written.
  @recorder_migration_version 20_260_807_130_000

  # Below this many DELIVERED rows the census refuses to compute a percentile at
  # all (the same law DeployLedger holds at n=200, scaled to this population).
  # With a 5x per-publish fan-out, 20 deliveries is ~4 independent publishes —
  # already thin. Under it the sample is reported and the percentiles are nil.
  @min_sample 20

  # How long a delivery may sit unmatched before it stops being "still waiting"
  # and becomes a finding. AutoDeployWorker debounces 60s (D44) and a site build
  # runs minutes, so anything shorter would report healthy builds as failures.
  # Being generous is the SAFE direction: it can only move rows OUT of
  # `never_delivered` and into `waiting_censored`, which is reported as a bound
  # and never as a percentile.
  @default_horizon_seconds 900

  @buckets ~w(delivered waiting_censored never_delivered site_never_live)

  # THE JOIN. Kept as literal SQL, not an Ecto lateral join, because this query's
  # correctness and its plan were both established by reading THIS text — the
  # predicates and their order are the artifact under review.
  @census_sql """
  SELECT p.id, p.site_id, p.received_at, p.doc_type, p.enqueued,
         d.id AS deployment_id, d.became_live_at
  FROM content_publishes p
  LEFT JOIN LATERAL (
    SELECT dd.id, dd.became_live_at
    FROM deployments dd
    WHERE dd.site_id = p.site_id
      AND dd.became_live_at IS NOT NULL
      -- PERFORMANCE PREDICATE ONLY. Logically implied by the guard below; here
      -- solely so the (site_id, became_live_at) partial index can SEEK instead
      -- of scanning the site's whole history (37,614 -> 55 buffers). Its premise
      -- (no row goes live before it is inserted) is checked by seek_bound/0.
      AND dd.became_live_at >= p.received_at
      -- THE HONESTY GUARD. A build already in flight when the publish arrived
      -- cannot be carrying it. Conservative by design: only ever under-credits.
      AND dd.inserted_at >= p.received_at
    ORDER BY dd.became_live_at
    LIMIT 1
  ) d ON TRUE
  WHERE p.received_at >= $1 AND p.received_at < $2
  """

  # Sites that went live at all from the window's start onward. Deliberately not
  # bounded above by `to`: a delivery near the end of the window may legitimately
  # go live after it, and bounding here would invent a `never_delivered`.
  @live_sites_sql """
  SELECT DISTINCT dd.site_id
  FROM deployments dd
  WHERE dd.became_live_at IS NOT NULL AND dd.became_live_at >= $1
  """

  @live_deploys_sql """
  SELECT count(*) FROM deployments dd
  WHERE dd.became_live_at IS NOT NULL
    AND dd.became_live_at >= $1 AND dd.became_live_at < $2
  """

  # The check that keeps the seek bound honest. If this ever leaves zero, the
  # bound is no longer free and the census must say so rather than quietly
  # dropping rows the guard would have kept.
  @seek_bound_sql """
  SELECT count(*) FROM deployments dd
  WHERE dd.became_live_at IS NOT NULL AND dd.became_live_at < dd.inserted_at
  """

  @recorder_since_sql """
  SELECT inserted_at FROM schema_migrations WHERE version = $1
  """

  @doc "The four bucket names, in report order."
  @spec buckets() :: [String.t()]
  def buckets, do: @buckets

  @doc "Delivered rows below this count produce no percentile at all."
  @spec min_sample() :: pos_integer()
  def min_sample, do: @min_sample

  @doc "Default seconds a delivery may go unmatched before it stops being 'waiting'."
  @spec default_horizon_seconds() :: pos_integer()
  def default_horizon_seconds, do: @default_horizon_seconds

  @doc "The join, verbatim. Quoted by the test so the predicates are pinned, not described."
  @spec census_sql() :: String.t()
  def census_sql, do: @census_sql

  @doc """
  When the recorder started observing, read from the MIGRATION instant — never
  from `min(received_at)`.

  `nil` when `schema_migrations` carries no row for the recorder's migration:
  the honest answer to "since when" on a database that never applied it is
  "unknown", not the earliest row it happens to hold.
  """
  @spec recorder_live_since() :: DateTime.t() | nil
  def recorder_live_since do
    case Repo.query!(@recorder_since_sql, [@recorder_migration_version]) do
      %{rows: [[%NaiveDateTime{} = at]]} -> DateTime.from_naive!(at, "Etc/UTC")
      _ -> nil
    end
  end

  @doc """
  The seek bound's premise, counted rather than assumed.

  Returns `%{violations: n, safe?: n == 0, note: …}`. `violations` is the number
  of deployments that went live BEFORE they were inserted — which is impossible
  today (0 of 30,648) and is exactly what makes `became_live_at >= received_at`
  a free predicate. A non-zero count does not corrupt the answer silently: the
  census carries this node so the reader sees the premise fail.
  """
  @spec seek_bound() :: %{violations: non_neg_integer(), safe?: boolean(), note: String.t()}
  def seek_bound do
    %{rows: [[violations]]} = Repo.query!(@seek_bound_sql, [])

    %{
      violations: violations,
      safe?: violations == 0,
      note:
        if(violations == 0,
          do:
            "became_live_at >= received_at is implied by the inserted_at guard: it drops nothing",
          else:
            "#{violations} deployments went live before they were inserted — the seek bound is no longer implied and may now be dropping rows the guard would keep"
        )
    }
  end

  @doc """
  The publish→web census over a PINNED `received_at` window (`from <= received_at < to`).

  Both bounds are required and explicit, for the same reason `DeployLedger.census/3`
  requires them (D3): a floating "now minus 24h" cannot be compared against
  itself a week later.

  Options:

    * `:now` — the instant "still waiting" is measured against. Defaults to
      `DateTime.utc_now/0`; pinned by tests.
    * `:horizon_seconds` — see `default_horizon_seconds/0`.
    * `:verify_seek_bound` — run `seek_bound/0` (default `true`).

  Returns a map, never prose. Shape:

      %{
        window: %{from: …, to: …},
        deliveries: 20, denominator_label: "deliveries",
        matched_deployments: 14, fan_out: %{n_to_1_ok?: true, …},
        buckets: [%{bucket: "delivered", count: 12, structurally_unreachable: false, note: …}, …],
        wait_seconds: %{sample: 12, refused: true, p50: nil, …},
        waiting: %{count: 3, at_least_seconds: 41.2, note: "…>= …"},
        censor: %{recorder_live_since: …, censored?: true, line: "…"},
        seek_bound: %{violations: 0, safe?: true, note: …},
        horizon_seconds: 900
      }
  """
  # `census` is a forked name in this codebase — `DeployLedger.census/3` counts
  # DEPLOY OUTCOMES over `deployments.inserted_at`; this one counts PUBLISH
  # DELIVERIES over `content_publishes.received_at`. An agent grepping "census"
  # or "time to web" lands on both, and only one of them starts at the human.
  # @canonical capability:publish-to-web-census aka:publish clock,time to web,publish latency,content_publishes reader
  @spec census(DateTime.t(), DateTime.t(), keyword()) :: map()
  def census(%DateTime{} = from, %DateTime{} = to, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    horizon = Keyword.get(opts, :horizon_seconds, @default_horizon_seconds)
    horizon_cut = DateTime.add(now, -horizon, :second)

    rows = load_rows(from, to)
    live_sites = load_live_sites(from)

    classified = Enum.map(rows, &classify(&1, horizon_cut, live_sites))

    delivered = Enum.filter(classified, &(&1.bucket == "delivered"))
    waiting = Enum.filter(classified, &(&1.bucket == "waiting_censored"))

    matched =
      delivered |> Enum.map(& &1.deployment_id) |> Enum.uniq() |> length()

    %{
      window: %{from: from, to: to},
      # DELIVERIES. Never "publishes" — one publish fans out to one row per
      # webhook-bound site, so this number is 5x the human action count.
      deliveries: length(rows),
      denominator_label: "deliveries",
      matched_deployments: matched,
      fan_out: %{
        deliveries: length(rows),
        delivered: length(delivered),
        matched_deployments: matched,
        # N:1 by construction — many deliveries may credit the same deployment,
        # and the reverse can never happen.
        n_to_1_ok?: length(delivered) >= matched,
        note:
          "content_publishes counts deliveries: one publish writes one row per webhook-bound site"
      },
      buckets: bucket_rows(classified),
      wait_seconds: wait_node(delivered),
      waiting: waiting_node(waiting, now),
      censor: censor_node(from, to, length(rows)),
      seek_bound: if(Keyword.get(opts, :verify_seek_bound, true), do: seek_bound(), else: nil),
      horizon_seconds: horizon
    }
  end

  ## ── The rows ──────────────────────────────────────────────────────────────

  defp load_rows(from, to) do
    %{rows: rows} = Repo.query!(@census_sql, [naive(from), naive(to)])

    Enum.map(rows, fn [
                        id,
                        site_id,
                        received_at,
                        doc_type,
                        enqueued,
                        deployment_id,
                        became_live_at
                      ] ->
      %{
        id: id,
        site_id: site_id,
        received_at: utc(received_at),
        doc_type: doc_type,
        enqueued: enqueued,
        deployment_id: deployment_id,
        became_live_at: utc(became_live_at)
      }
    end)
  end

  defp load_live_sites(from) do
    %{rows: rows} = Repo.query!(@live_sites_sql, [naive(from)])
    MapSet.new(rows, fn [site_id] -> site_id end)
  end

  defp live_deploy_count(from, to) do
    %{rows: [[count]]} = Repo.query!(@live_deploys_sql, [naive(from), naive(to)])
    count
  end

  ## ── The four buckets ──────────────────────────────────────────────────────

  defp classify(%{deployment_id: id} = row, _horizon_cut, _live_sites) when not is_nil(id) do
    Map.merge(row, %{
      bucket: "delivered",
      wait_seconds: seconds_between(row.received_at, row.became_live_at)
    })
  end

  defp classify(row, horizon_cut, live_sites) do
    bucket =
      cond do
        # Newer than the horizon: it may still land. Its wait is a LOWER BOUND.
        DateTime.compare(row.received_at, horizon_cut) == :gt -> "waiting_censored"
        MapSet.member?(live_sites, row.site_id) -> "never_delivered"
        true -> "site_never_live"
      end

    Map.merge(row, %{bucket: bucket, wait_seconds: nil})
  end

  defp bucket_rows(classified) do
    counts = Enum.frequencies_by(classified, & &1.bucket)

    Enum.map(@buckets, fn bucket ->
      %{
        bucket: bucket,
        count: Map.get(counts, bucket, 0),
        structurally_unreachable: bucket == "site_never_live",
        note: bucket_note(bucket)
      }
    end)
  end

  defp bucket_note("delivered"),
    do: "a live deployment was found forward of the delivery — the only bucket in a percentile"

  defp bucket_note("waiting_censored"),
    do:
      "right-censored: newer than the horizon, no match yet; its wait is reported as >= elapsed and NEVER folded into a percentile"

  defp bucket_note("never_delivered"),
    do: "older than the horizon with no match, on a site that DID go live in this window"

  defp bucket_note("site_never_live"),
    do:
      "STRUCTURALLY UNREACHABLE through this recorder: ContentPublish.record/3 writes only on the HMAC-verified content-webhook arm, whose sites all go live. A constant zero here is the shape of the recorder, not evidence of health"

  ## ── The numbers ───────────────────────────────────────────────────────────

  defp wait_node(delivered) do
    waits = delivered |> Enum.map(& &1.wait_seconds) |> Enum.sort()
    sample = length(waits)

    if sample < @min_sample do
      %{
        sample: sample,
        min_sample: @min_sample,
        refused: true,
        reason: "sample #{sample} below min_sample #{@min_sample}",
        p50: nil,
        p90: nil,
        p99: nil,
        max: nil
      }
    else
      %{
        sample: sample,
        min_sample: @min_sample,
        refused: false,
        reason: nil,
        p50: percentile(waits, 50),
        p90: percentile(waits, 90),
        p99: percentile(waits, 99),
        max: List.last(waits)
      }
    end
  end

  # Nearest-rank, on the DELIVERED rows only. A censored row has no value to
  # sort, so it cannot enter here even by accident.
  defp percentile(sorted, p) do
    index = max(round(Float.ceil(p / 100 * length(sorted))) - 1, 0)
    Enum.at(sorted, index)
  end

  defp waiting_node([], _now),
    do: %{count: 0, at_least_seconds: nil, note: "no deliveries are still within the horizon"}

  defp waiting_node(waiting, now) do
    longest =
      waiting
      |> Enum.map(&seconds_between(&1.received_at, now))
      |> Enum.max()

    %{
      count: length(waiting),
      at_least_seconds: longest,
      note:
        "right-censored: the true wait is unknown and is only bounded — the oldest is >= #{longest}s. Never a percentile"
    }
  end

  ## ── The censor line ───────────────────────────────────────────────────────

  defp censor_node(from, to, deliveries) do
    since = recorder_live_since()

    line =
      cond do
        is_nil(since) ->
          "recorder start UNKNOWN — schema_migrations carries no row for version #{@recorder_migration_version}; every count in this window is censored by an unknown amount"

        deliveries == 0 ->
          "0 of #{live_deploy_count(from, to)} live deploys in this window carry a recorded publish delivery; recorder live since #{DateTime.to_iso8601(since)}; the population before that instant is censored, not zero"

        DateTime.compare(from, since) == :lt ->
          "#{deliveries} deliveries recorded; recorder live since #{DateTime.to_iso8601(since)}; this window opens before that instant, so publishes in the earlier part are censored, not absent"

        true ->
          nil
      end

    %{
      recorder_live_since: since,
      # The window is censored whenever it reaches back past the recorder, and
      # ALWAYS when nothing was recorded — "no rows" is never proof of "no
      # publishes".
      censored?: not is_nil(line),
      line: line,
      source: "schema_migrations.inserted_at for version #{@recorder_migration_version}"
    }
  end

  ## ── Time ──────────────────────────────────────────────────────────────────

  defp naive(%DateTime{} = dt), do: DateTime.to_naive(dt)

  defp utc(nil), do: nil
  defp utc(%NaiveDateTime{} = nd), do: DateTime.from_naive!(nd, "Etc/UTC")

  defp seconds_between(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.diff(b, a, :microsecond) / 1_000_000
end
