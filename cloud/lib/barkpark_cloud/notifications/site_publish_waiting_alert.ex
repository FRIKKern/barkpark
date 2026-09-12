defmodule BarkparkCloud.Notifications.SitePublishWaitingAlert do
  @moduledoc """
  dr-w11-s5-waiting-alert — THE ALERT POINTS AT THE WAIT. One email when a
  team has content that has been sitting unpublished for longer than
  `threshold_seconds/0`, and one more when that wait CLEARS, naming how long it
  lasted.

  ## The fault this closes

  The epic's founding sentence — "nothing reports it" — is refuted for
  FAILURES and true for WAITS. `notification_deliveries` held 2,291
  `deployment_failed` emails at 870/day on 2026-08-06, default-ON for all 22
  teams, wired at three producers. What it has NEVER sent is one notification
  about a revision sitting unpublished — and the same ledger says nothing was
  stranded, so the fleet has been emailing ~870 times a day about attempts that
  destroyed no content and zero times about the wait that actually reaches a
  customer. The reporting is not missing; it is pointed at the wrong quantity.

  ## Where the cohort comes from — ONE call site, and it is not ours

  `DeployLedger.delivery/3` (`deploy_ledger.ex`, `delivery/3`) already computes the
  STILL-WAITING cohort: every site node it returns carries `still_waiting` and
  `oldest_waiting_seconds`, folded from the same censored observations its
  percentiles are taken over. This module writes NO query. That is the
  `DeployRateAlert` contract repeated for the same reason — a second,
  independently-written "which sites are waiting" query is two definitions of
  the same cohort, and the one that reaches a human is then a coin toss — and
  here it buys three specific things a hand-written query would have got wrong:

    * **CANCELLED ROWS ARE NOT WAITS.** `delivery/3` splits `status ==
      "cancelled"` into its own counted bucket
      (`dr-w11-bl-cancelled-rows-count-as-waiting`). A naive
      "newest attempt post-dates newest live row" query emails a team
      "STILL WAITING >= 3d" about a deploy the team itself stopped.
    * **UNMETERED ROWS ARE NOT WAITS EITHER.** A `live` row with no
      `became_live_at` reached the web at a time the ledger cannot name; it is
      counted as `unmetered`, never censored. jarl-website has 55 such rows.
    * **A ROW IS DELIVERED BY THE SITE'S NEXT LIVE MARK**, not only by its own
      terminal. A failed attempt followed by a successful one waited until that
      successful one landed — and then stopped waiting. Subtracting timestamps
      would still be counting it.

  ## The threshold, DERIVED (charter D161/D162)

  `3600s` — one hour. Taken against the corpus measurement recorded in
  `DeployLedger`'s own `delivery/3` moduledoc, re-measured 2026-08-09 on
  cloud-db-1 over THIS clock (attempt `inserted_at` → `became_live_at`,
  floored):

      p95 = 948.782s over a 24h window (censored_fraction 0.0139)
      p95 = 1256.78s over a 72h window (censored_fraction 0.0027)

  One hour is 3.79x the 24h-window p95 and 2.86x the 72h-window p95. It is
  deliberately NOT set AT p95: a threshold at p95 fires on one publish in
  twenty, which is the alarm-fatigue shape this slice exists to refuse. The
  margin is the same argument `DeployRateAlert` makes for its 25% — the alert
  must sit above a bad day, not on top of the ordinary distribution, and the
  epic's own baseline is the evidence.

  EVERY PERCENTILE IS QUOTED WITH ITS WINDOW, because the same healthy fleet
  reads p95 948.8s at 24h and 211,338s at 7d — a spread produced by the window
  width alone. `window_seconds/0` therefore pins the door this alert reads at
  24h, the same width the quoted p95 was taken over. A threshold and a
  percentile measured over different windows are not comparable numbers.

  ## Edge-guarded by a LATCH, and the threshold is the debounce

  `DeployRateAlert` needs a consecutive-tick counter because a rolling failure
  RATE is noisy at the edge. A wait past a fixed threshold is not: the
  threshold itself is the debounce, so the guard here is the `alerted_at` latch
  alone, carried on the SAME `DeployRateAlertState` row rather than in a second
  store. Three sweeps with the same site still waiting send exactly ONE email;
  the latch clears the moment the verdict leaves `:waiting`, which re-arms the
  notice for the next episode.

  ## `:unmeasured` is not `:clear`

  A truncated site list, an absent envelope or a delivery node this module
  cannot read is `:unmeasured` — never `:clear`. `delivery/3` truncates `sites`
  to `site_limit` and reports `truncated: true`; a cut list could hide the very
  site that is waiting, so a reading taken over one is refused rather than
  reported as a clean bill. That is charter D3's rule: a fleet nobody could
  measure must not resolve to good news.
  """
  import Swoosh.Email

  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Mailer

  # THE THRESHOLD. See the moduledoc: 3.79x the measured 24h-window p95 of
  # 948.782s (cloud-db-1, 2026-08-09, this clock).
  @threshold_seconds 3600

  # THE DOOR. 24h — the same width the quoted p95 was measured over. A wait
  # whose attempt row fell out of this window is no longer visible to this
  # alert; that is a stated limit of the door, not a silent one (see
  # `window_seconds/0`).
  @window_seconds 86_400

  # The site cap handed to `delivery/3`. It defaults to 50 and cuts SILENTLY at
  # the envelope level; a cut list could omit the waiting site entirely, so this
  # asks for far more than the fleet has and REFUSES the reading if the envelope
  # still comes back `truncated: true`.
  @site_limit 5_000

  @type verdict :: :waiting | :clear | :unmeasured

  @doc "Seconds a site must have been waiting before this alert reads WAITING."
  @spec threshold_seconds() :: pos_integer()
  def threshold_seconds, do: @threshold_seconds

  @doc "The width of the pinned door the cohort is read over."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc "The site cap handed to `DeployLedger.delivery/3`."
  @spec site_limit() :: pos_integer()
  def site_limit, do: @site_limit

  @doc """
  Read one team's still-waiting cohort out of `DeployLedger.delivery/3`.

  `site_ids` is the team's OWN sites — `delivery/3`'s `:site_ids` option puts
  the predicate IN the query, which is the only place it can go: the envelope's
  percentiles are folded before any downstream filter could run, so a
  post-filter would print fleet-wide numbers under one team's name.
  """
  @spec read(DateTime.t(), [binary()]) :: map()
  def read(%DateTime{} = now, site_ids) when is_list(site_ids) do
    from = DateTime.add(now, -@window_seconds, :second)

    DeployLedger.delivery(from, now,
      site_ids: site_ids,
      site_limit: @site_limit,
      as_of: now
    )
  end

  @doc """
  The verdict for one `read/2` envelope.

  `:waiting` when at least one site node is still waiting past
  `threshold_seconds/0`; `:clear` when the cohort is readable and no site is;
  `:unmeasured` for every absence — a missing `sites` node, or an envelope
  `delivery/3` marked `truncated`.
  """
  @spec verdict(map()) :: verdict()
  def verdict(%{truncated: true}), do: :unmeasured

  def verdict(%{sites: sites}) when is_list(sites) do
    if Enum.any?(sites, &over_threshold?/1), do: :waiting, else: :clear
  end

  def verdict(_envelope), do: :unmeasured

  @doc """
  The site nodes that are waiting past the threshold, longest wait first.
  Always `[]` for an unreadable or truncated envelope.
  """
  @spec waiting_sites(map()) :: [map()]
  def waiting_sites(%{truncated: true}), do: []

  def waiting_sites(%{sites: sites}) when is_list(sites) do
    sites
    |> Enum.filter(&over_threshold?/1)
    |> Enum.sort_by(& &1.oldest_waiting_seconds, :desc)
  end

  def waiting_sites(_envelope), do: []

  @doc """
  The longest wait in the cohort, in seconds, or `nil` when nothing is waiting
  past the threshold. This is the number the notice leads with and the number
  the RECOVERY message reports back.
  """
  @spec longest_wait_seconds(map()) :: float() | nil
  def longest_wait_seconds(envelope) do
    envelope
    |> waiting_sites()
    |> Enum.map(& &1.oldest_waiting_seconds)
    |> Enum.max(fn -> nil end)
  end

  # A node counts only when the ledger gave it BOTH answers: it says it is
  # waiting AND it can name for how long. `still_waiting: true` with a nil
  # duration is a node this alert cannot put a number on, and it must not be
  # rendered as a wait of unknown length.
  defp over_threshold?(%{still_waiting: true, oldest_waiting_seconds: secs})
       when is_number(secs),
       do: secs >= @threshold_seconds

  defp over_threshold?(_node), do: false

  ## ── The copy ─────────────────────────────────────────────────────────────

  # THE CLOCK SENTENCE, and it is the one thing in this module that is pinned by
  # a test as a literal string (dr-w11-s5 criterion 6).
  #
  # It names the control-plane pickup, NOT the human's publish, because that is
  # what the number IS: `delivery/3` keys on the deployment row's own
  # `inserted_at`. Until dr-w11-s1's publish-keyed t0 is live, any copy saying
  # "since you published" is off by the whole queue wait ahead of the row, and a
  # customer reading it would be told a duration the ledger never measured. The
  # wording tracks slice dr-w11-s2's; the envelope's own `clock` field is
  # printed underneath it so the copy can never drift from the ledger's name for
  # its own clock.
  @clock_sentence "Measured from when the control plane PICKED THE PUBLISH UP — the deployment row's own inserted_at — not from when you pressed publish."

  @doc "The clock sentence this notice's copy is pinned to."
  @spec clock_sentence() :: String.t()
  def clock_sentence, do: @clock_sentence

  @doc """
  Build (never send) the WAITING notice for one recipient.

  The subject carries the duration AND how many sites are waiting, because a
  subject line is the part of an alert most likely to be read alone.
  """
  @spec build(map(), String.t()) :: Swoosh.Email.t()
  def build(envelope, recipient) when is_binary(recipient) do
    new()
    |> to(recipient)
    |> from(Mailer.from())
    |> subject(subject(envelope))
    |> text_body(body(envelope))
  end

  @doc "The WAITING subject line: the longest wait and the size of the cohort."
  @spec subject(map()) :: String.t()
  def subject(envelope) do
    sites = waiting_sites(envelope)
    longest = longest_wait_seconds(envelope)

    "Barkpark: content still WAITING to reach the web — #{format_duration(longest)} " <>
      "(#{count_sites(length(sites))})"
  end

  @doc "The WAITING notice body."
  @spec body(map()) :: String.t()
  def body(envelope) do
    sites = waiting_sites(envelope)

    """
    Barkpark publish wait — this team's own sites.

    Longest wait: #{format_duration(longest_wait_seconds(envelope))}, over #{count_sites(length(sites))}.
    Threshold: #{format_duration(@threshold_seconds)}.

    #{@clock_sentence}
    Clock: #{Map.get(envelope, :clock, "unnamed")}
    Window: #{span(envelope)} (pinned; both bounds explicit).

    #{site_lines(sites)}

    WHY THIS AND NOT A FAILURE EMAIL. A failed deploy that a later deploy
    replaced destroyed no content — the ledger records nothing stranded. A
    publish that has not reached the web is the thing a reader of your site can
    actually see. This notice is keyed on that wait, not on the attempt count.

    WHY THE THRESHOLD IS #{format_duration(@threshold_seconds)}. The measured 95th percentile of time-to-web
    over a 24h door is 948.782s (cloud-db-1, 2026-08-09, this clock). This
    threshold sits #{Float.round(@threshold_seconds / 948.782, 2)}x above it, so an ordinary slow publish does not
    reach your inbox. A percentile and a threshold measured over different
    windows are not comparable numbers, so the door this alert reads is the same
    24h the figure above was taken over.

    THIS IS ONE EMAIL PER EPISODE, NOT ONE PER SWEEP. Nothing further is sent
    while the wait stands. When it clears you get exactly one more message
    saying so, with the duration it lasted.

    TO STOP THESE. This notice rides the team's `deployment_failed` toggle — the
    same switch that already governs deploy alert mail. Turn that off (or
    `alerts_enabled` off) in the console's notification settings and it stops,
    with no new checkbox to find.

    This is an automated operator notice from Barkpark Cloud.\
    """
  end

  @doc """
  Build (never send) the RECOVERY notice — the wait cleared.

  `longest_seconds` is the longest wait the ledger measured during the episode;
  `episode_seconds` is how long this alert itself stood, from the instant the
  notice went out to the sweep that saw it clear. Both are printed: the first is
  what the customer's content endured, the second is what the alert asserted,
  and they are not the same number.
  """
  @spec build_recovery(number() | nil, number() | nil, String.t()) :: Swoosh.Email.t()
  def build_recovery(longest_seconds, episode_seconds, recipient) when is_binary(recipient) do
    new()
    |> to(recipient)
    |> from(Mailer.from())
    |> subject(recovery_subject(longest_seconds))
    |> text_body(recovery_body(longest_seconds, episode_seconds))
  end

  @doc "The RECOVERY subject line. It names the duration, which is the point."
  @spec recovery_subject(number() | nil) :: String.t()
  def recovery_subject(longest_seconds) do
    "Barkpark: content reached the web — the publish wait of " <>
      "#{format_duration(longest_seconds)} has CLEARED"
  end

  @doc "The RECOVERY notice body."
  @spec recovery_body(number() | nil, number() | nil) :: String.t()
  def recovery_body(longest_seconds, episode_seconds) do
    """
    Barkpark publish wait — CLEARED.

    No site of this team's is now waiting past #{format_duration(@threshold_seconds)}.

    Longest wait measured during the episode: #{format_duration(longest_seconds)}.
    The alert stood for: #{format_duration(episode_seconds)}.

    #{@clock_sentence}

    WHY YOU ARE GETTING GOOD NEWS. An instrument that can only accuse is an
    alarm. The earlier notice told you content was not on the web; this one
    tells you it is, and how long that took, so the two messages are a measured
    interval rather than an open-ended worry.

    This is an automated operator notice from Barkpark Cloud.\
    """
  end

  ## ── Rendering ────────────────────────────────────────────────────────────

  defp site_lines([]), do: "No site is currently over the threshold."

  defp site_lines(sites) do
    sites
    |> Enum.map(fn site ->
      "  - site #{site.site_id}: waiting at least #{format_duration(site.oldest_waiting_seconds)}" <>
        " (#{Map.get(site, :censored, 0)} of #{Map.get(site, :sample, 0)} attempts in this window not yet delivered)"
    end)
    |> Enum.join("\n")
  end

  defp count_sites(1), do: "1 site"
  defp count_sites(n), do: "#{n} sites"

  # A DURATION IS NEVER PRINTED BARE. `nil` is the honest answer when the ledger
  # could not name one, and it must not render as "0s" — a zero reads as "no
  # wait", which is the opposite of "a wait nobody could measure".
  defp format_duration(nil), do: "an unnamed duration"

  defp format_duration(seconds) when is_number(seconds) do
    total = round(seconds)

    cond do
      total < 60 -> "#{total}s"
      total < 3600 -> "#{div(total, 60)}m #{rem(total, 60)}s"
      total < 86_400 -> "#{div(total, 3600)}h #{div(rem(total, 3600), 60)}m"
      true -> "#{div(total, 86_400)}d #{div(rem(total, 86_400), 3600)}h"
    end
  end

  defp span(%{window: %{from: %DateTime{} = from, to: %DateTime{} = to}}),
    do: "#{format_ts(from)} to #{format_ts(to)}"

  defp span(_envelope), do: "unknown"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
