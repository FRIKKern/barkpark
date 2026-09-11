defmodule BarkparkCloud.Notifications.BoxUnreachableEpisodeAlert do
  @moduledoc """
  dr-w32-bl-box-unreachable-needs-an-episode-alarm — THE EPISODE ALARM for
  `BOX_UNREACHABLE`. One email when a team's deploy ledger shows an EPISODE of
  the box being unreachable, and never one email per unreachable row.

  ## The class this watches, and why it is an alarm target rather than a bug

  `BOX_UNREACHABLE` is what `DeployLedger.classify/2` names a failed deploy whose
  `failure_reason` says the instance could not be reached — in production, one
  string: *"instance guerrilla is unreachable — the deploy could not be
  delivered; check instance health"*. Measured over 24 days on the live ledger
  (wave 32, charter D549) it is CHRONIC and EPISODIC: gap-grouped at 30 minutes,
  143 rows fall into 58 EPISODES across 6 sites, every one of which SELF-HEALED.
  The largest was 14 rows over 1h51m; the MEDIAN was one single row.

  A class that always recovers on its own is not a cure target and not a code
  defect. It is an incident class, and the missing instrument is an ALARM.

  ## WHY THE ALARM IS EPISODE-SHAPED AND NEVER PER-ROW

  The median episode is ONE ROW. A per-row producer would therefore fire on the
  median episode, which is a single deploy retrying against a box that came back
  within seconds — 58 emails in 24 days for 58 non-events. That alarm is muted
  inside a week, and a muted alarm makes the epic's own exit gauge worthless.

  So the reading is a SHAPE: how many rows, across how many SITES, inside a
  pinned window. See `min_rows/0`, `min_sites/0` and `window_minutes/0` for the
  derivation of each number from the measured baseline.

  ## Three verdict words, and `:unmeasured` is not `:clear`

  `:episode` / `:clear` / `:unmeasured`, the same vocabulary and the same rule
  the rate alert and the publish-waiting alert already use: a team whose site
  list could not be read is UNMEASURED, never CLEAR. A fleet nobody could
  measure must not resolve to a clean bill (charter D3), and collapsing it into
  `clear` here would additionally send a RECOVERY message for an episode that
  may still be standing.

  ## THE CLASS IS INHERITED, NOT RE-IMPLEMENTED

  `read/2` runs ONE grouped query and hands every group to
  `DeployLedger.classify/1` — the same classifier the census, the digest and the
  console class table read. A predicate written here (`failure_reason LIKE '%is
  unreachable%'`) would be a SECOND definition of the class, and the day the
  ledger's prose marker moves the two answers diverge with nothing to notice it.

  The grouping — `site_id, stage, failure_reason` with `count`, `min` and `max`
  of `inserted_at` — is the census's own group shape, so the cost is bounded by
  group CARDINALITY and not by row count, and the span the alarm quotes is
  computed by Postgres over the rows themselves.
  """
  # NOT `import Ecto.Query`: `Swoosh.Email` and `Ecto.Query` both export `from/2`
  # and importing both makes every call site ambiguous. The email builders below
  # want Swoosh's, so the ONE query in this module qualifies Ecto's.
  import Swoosh.Email

  require Ecto.Query

  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Mailer
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Repo

  @class "BOX_UNREACHABLE"

  # ── THE THRESHOLD, DERIVED FROM A STATED QUIET BASELINE ──────────────────
  #
  # THE QUIET BASELINE, WITH ITS WINDOW PINNED: 2026-08-09 05:00Z → 16:00Z on
  # the production ledger — 480 deploy attempts, ZERO BOX_UNREACHABLE rows,
  # eleven consecutive zero-failure hours. The quiet floor for this class is
  # therefore literally 0 rows/hour, measured, not assumed.
  #
  # THE EPISODE DISTRIBUTION, SAME CORPUS, 24 days: 143 rows / 58 episodes /
  # 6 sites, gap-grouped at 30 minutes. MEDIAN EPISODE = 1 row. Largest =
  # 14 rows over 1h51m.
  #
  # THE INCIDENT THE ALARM MUST CATCH: 2026-08-09 17:00Z — 9 rows across 6 sites
  # spanning 00:02:47.86, all stage PLAN, deploys live again at 17:36.
  #
  # Each number below is the SMALLEST value strictly above the quiet baseline
  # AND strictly above the median episode, that the measured burst still clears
  # by a wide margin. None of the three is picked by feel.

  # T — THE WINDOW. One hour, because that is the grain the baseline was
  # measured at (eleven consecutive zero-failure HOURS) and the cadence
  # `DeployRateAlertWorker` already ticks at. A shorter window would be a
  # threshold measured against a baseline that was never taken at that width.
  @window_minutes 60

  # N — ROWS. 3 in one hour. The quiet baseline produced 0/hour for 11 hours;
  # the median episode is 1 row; 2 is one retry of a 1-row episode. 3 is the
  # first count outside BOTH the quiet period and the median episode, and the
  # burst clears it 3x (9 rows) inside its first three minutes.
  @min_rows 3

  # M — SITES. 2. This is the term that says BOX, not SITE. Three rows on ONE
  # site is one publish retrying and can be produced by a site-local fault; the
  # signature of an unreachable BOX is that unrelated sites fail together — the
  # measured burst hit 6 of them. The median episode is 1 row and therefore
  # 1 site, so 2 is again the first value outside it.
  @min_sites 2

  @type verdict :: :episode | :clear | :unmeasured

  @doc "The class this alarm watches, as `DeployLedger.classify/2` names it."
  @spec class() :: String.t()
  def class, do: @class

  @doc "T — the pinned window width, in minutes."
  @spec window_minutes() :: pos_integer()
  def window_minutes, do: @window_minutes

  @doc "N — BOX_UNREACHABLE rows in the window at or above which a reading fires."
  @spec min_rows() :: pos_integer()
  def min_rows, do: @min_rows

  @doc "M — distinct sites in the window at or above which a reading fires."
  @spec min_sites() :: pos_integer()
  def min_sites, do: @min_sites

  @doc """
  Read one team's `BOX_UNREACHABLE` shape over the window ending at `now`.

  BOTH BOUNDS ARE EXPLICIT and computed from `now` here, then carried in the
  reading, so the number can be compared against itself tomorrow (charter D3).
  The door is half-open: `from <= inserted_at < to`.

  `site_ids` MUST be the team's own intersection. `[]` is read as UNMEASURED and
  never as `clear` — a team with nothing to look at has not been given a clean
  bill of health.
  """
  @spec read(DateTime.t(), [Ecto.UUID.t()] | term()) :: map()
  def read(%DateTime{} = now, site_ids) when is_list(site_ids) and site_ids != [] do
    from_dt = DateTime.add(now, -@window_minutes * 60, :second)

    groups =
      Repo.all(
        Ecto.Query.from(d in Deployment,
          where: d.inserted_at >= ^from_dt and d.inserted_at < ^now,
          where: d.site_id in ^site_ids,
          where: d.status == "failed",
          group_by: [d.site_id, d.stage, d.failure_reason],
          select: %{
            site_id: d.site_id,
            stage: d.stage,
            status: "failed",
            failure_reason: d.failure_reason,
            count: count(d.id),
            first_at: min(d.inserted_at),
            last_at: max(d.inserted_at)
          }
        )
      )

    hits = Enum.filter(groups, &(DeployLedger.classify(&1) == @class))

    %{
      from: from_dt,
      to: now,
      rows: Enum.reduce(hits, 0, &(&1.count + &2)),
      sites: hits |> Enum.map(& &1.site_id) |> Enum.uniq() |> length(),
      first_at: hits |> Enum.map(& &1.first_at) |> min_dt(),
      last_at: hits |> Enum.map(& &1.last_at) |> max_dt(),
      unmeasured: false
    }
  end

  def read(%DateTime{} = _now, _site_ids), do: %{unmeasured: true}

  @doc """
  The verdict for one `read/2` reading.

  `:episode` needs BOTH terms — `rows >= min_rows/0` AND `sites >= min_sites/0`.
  Either alone is a shape the ledger produces routinely.
  """
  @spec verdict(map()) :: verdict()
  def verdict(%{unmeasured: true}), do: :unmeasured

  def verdict(%{rows: rows, sites: sites}) when is_integer(rows) and is_integer(sites) do
    if rows >= @min_rows and sites >= @min_sites, do: :episode, else: :clear
  end

  def verdict(_reading), do: :unmeasured

  @doc """
  The span the episode's rows actually cover, in seconds, or `nil` when the
  reading has fewer than two timestamps to span.
  """
  @spec span_seconds(map()) :: integer() | nil
  def span_seconds(%{first_at: %DateTime{} = a, last_at: %DateTime{} = b}),
    do: DateTime.diff(b, a)

  def span_seconds(_reading), do: nil

  @doc "Build (never send) the episode notice for one recipient."
  @spec build(map(), String.t()) :: Swoosh.Email.t()
  def build(reading, recipient) when is_binary(recipient) do
    new()
    |> to(recipient)
    |> from(Mailer.from())
    |> subject(subject(reading))
    |> text_body(body(reading))
  end

  @doc "Build (never send) the RECOVERY notice for one recipient."
  @spec build_recovery(non_neg_integer(), non_neg_integer(), non_neg_integer(), String.t()) ::
          Swoosh.Email.t()
  def build_recovery(peak_rows, peak_sites, episode_seconds, recipient)
      when is_binary(recipient) do
    new()
    |> to(recipient)
    |> from(Mailer.from())
    |> subject("Barkpark: the box is reachable again")
    |> text_body(recovery_body(peak_rows, peak_sites, episode_seconds))
  end

  @doc "The subject: the shape, never a bare count."
  @spec subject(map()) :: String.t()
  def subject(reading) do
    "Barkpark: the instance was unreachable — #{Map.get(reading, :rows, 0)} " <>
      "undeliverable deploys across #{Map.get(reading, :sites, 0)} sites in the last " <>
      "#{@window_minutes} minutes"
  end

  @doc """
  The notice body: what fired, what the threshold IS and where it came from,
  that this class self-heals, and how to make it stop.
  """
  @spec body(map()) :: String.t()
  def body(reading) do
    """
    Barkpark could not DELIVER deploys to this team's instance.

    Class: #{@class} — #{DeployLedger.label(@class)}.
    Reading: #{Map.get(reading, :rows, 0)} rows across #{Map.get(reading, :sites, 0)} sites.
    Rows span: #{format_span(span_seconds(reading))}.
    Window: #{span(reading)} (both bounds pinned at read time; half-open).

    THE THRESHOLD, AND WHERE IT CAME FROM. This fires at #{@min_rows} or more rows across
    #{@min_sites} or more sites inside #{@window_minutes} minutes. The quiet baseline it is
    derived from is a pinned window on this ledger — 2026-08-09 05:00Z to 16:00Z,
    480 deploy attempts, ZERO rows of this class, eleven consecutive zero-failure
    hours — and the episode distribution beside it: 143 rows in 58 episodes over
    24 days, MEDIAN EPISODE ONE ROW. #{@min_rows} rows on #{@min_sites} sites is the smallest shape
    outside both. It is not a number anybody felt was about right.

    THIS CLASS HAS ALWAYS SELF-HEALED. All 58 measured episodes recovered without
    intervention, the largest after 1h51m. This mail is not a request to rebuild
    anything: it says the control plane could not REACH the box, so the deploys in
    the window were never delivered and nothing was lost on the box side. They are
    re-driven when it answers again.

    THIS IS NOT ONE EMAIL PER UNREACHABLE ROW. It is one per EPISODE: nothing
    further is sent until the reading goes clear, at which point a single recovery
    message names how long it stood.

    TO STOP THESE. This notice rides the team's `agent_unreachable` toggle — the
    same subject (this instance cannot be reached), one grain coarser. Turn that
    off (or `alerts_enabled` off) in the console's notification settings and it
    stops, with no new checkbox to find.

    This is an automated operator notice from Barkpark Cloud.\
    """
  end

  ## ── Rendering ────────────────────────────────────────────────────────────

  defp recovery_body(peak_rows, peak_sites, episode_seconds) do
    """
    Barkpark is reaching this team's instance again — #{@class} has cleared.

    At its worst the episode showed #{peak_rows} undeliverable deploys across #{peak_sites} sites
    in one #{@window_minutes}-minute window. The alert stood for #{format_span(episode_seconds)}.

    Deploys that could not be delivered while the box was unreachable were never
    started on it. Nothing needs to be cleaned up; re-publish anything whose
    content you expect on the web and it will go through.

    This is an automated operator notice from Barkpark Cloud.\
    """
  end

  defp format_span(nil), do: "unknown"
  defp format_span(0), do: "under a second"

  defp format_span(seconds) when is_integer(seconds) do
    h = div(seconds, 3600)
    m = seconds |> rem(3600) |> div(60)
    s = rem(seconds, 60)

    cond do
      h > 0 -> "#{h}h #{m}m #{s}s"
      m > 0 -> "#{m}m #{s}s"
      true -> "#{s}s"
    end
  end

  defp span(%{from: %DateTime{} = from, to: %DateTime{} = to}),
    do: "#{format_ts(from)} to #{format_ts(to)}"

  defp span(_reading), do: "unknown"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp min_dt([]), do: nil
  defp min_dt(list), do: Enum.min(list, DateTime)

  defp max_dt([]), do: nil
  defp max_dt(list), do: Enum.max(list, DateTime)
end
