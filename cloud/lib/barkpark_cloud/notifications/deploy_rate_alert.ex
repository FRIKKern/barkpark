defmodule BarkparkCloud.Notifications.DeployRateAlert do
  @moduledoc """
  dr-bl-rate-notice — THE RATE NOTICE. One email when a team's deploy FAILURE
  RATE has stood above `alert_pct/0` for `consecutive_ticks/0` consecutive
  hourly readings, and not one email per failed deployment.

  ## The fault this closes

  `deployment_failed` already fires, three producers deep: 840 emails in three
  days to one inbox, peaking at 135 in an hour, the first landing 3m24s after
  PR #9407 merged. Charter D14 rules that on a fleet failing thousands of times
  the missing instrument is a RATE, and forbids adding an 841st per-deployment
  producer. Nothing in this module produces one: it never sees a deployment row,
  it reads a census.

  ## Where the number comes from — ONE call site, and it is not ours

  The reading is `DigestEmail.deploy_health/1`, which is the ONLY caller of
  `DeployLedger.census/3` on this rail (`digest_email.ex`'s `window_health/3`,
  `census(from, now, site_ids: site_ids, site_limit: 0)`). This module writes no
  query of its own — a second, independently-written fleet-rate query is two
  definitions of the same number, and the one that reaches a human is then a
  coin toss.

  That inheritance is not a convenience, it is most of the contract:

    * **THE WINDOW IS PINNED.** `deploy_health/1` pins both bounds at its `:now`
      and hands them to `census/3` explicitly. A floating "now minus 24h" cannot
      be compared against itself tomorrow (charter D3).
    * **THE VOLUME RIDES WITH THE PERCENTAGE.** `DeployLedger.rate/2` returns
      `%{pct, sample, numerator, min_sample, refused, reason, basis}` precisely
      so no caller can print a percentage without its denominator. The subject
      line and the body both carry `numerator of sample`, from that node.
    * **IT REFUSES BELOW n = `DeployLedger.min_sample/0` (200).** Not by a check
      in this module — by the node arriving `refused: true, pct: nil`, which
      `verdict/1` reads as `:unmeasured` and never as `:clear`. Delete the
      threshold constant here and the refusal is still total.

  ## The SETTLED basis, not the attempted one (D525)

  The verdict reads `census.terminal_failure_rate` (`failed / (failed + live)`),
  carried through as `window.terminal_rate`. The attempted-basis rate includes
  DEFERRALS in its denominator, and a deferral is a WAIT, not an outcome: a
  fleet under capacity pressure defers more, which LOWERS the attempted-basis
  percentage with no change in reliability at all. An alert keyed on that number
  goes quiet exactly when the platform is at its most congested. The settled
  denominator cannot be moved that way. The body prints both, because D525 says
  neither basis may be quoted alone; only the settled one is allowed to decide.

  ## Three verdict words, and `:unmeasured` is not `:clear`

  `:red` / `:clear` / `:unmeasured`. A refused sample, a window with no rows, a
  team with no sites and an unreadable ledger are all `:unmeasured` — a fleet
  nobody could measure must never resolve to a clean bill, which is the whole
  reason `deploy_health/1` renders the word rather than 0%.

  `:unmeasured` also RESETS the consecutive counter (see
  `DeployRateAlertState`): a run of red broken by an hour nobody could read is
  not a run of red.
  """
  import Swoosh.Email

  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Mailer

  # THE DOOR THIS VERDICT IS TAKEN OVER, named by the label
  # `DigestEmail.@deploy_windows` gives it. Selecting by LABEL and not by
  # position: the digest reports two doors and may one day report three, and a
  # verdict silently re-anchored onto a 7d window by an insertion would change
  # what this alert means without changing a line here.
  @window_label "last 24h"

  # THE THRESHOLD. A settled-basis failure rate at or above this reads red.
  #
  # 25% is chosen against the corpus that motivated the epic, not against
  # intuition: the 2026-08-08 outage — five sites, 18 failures across 4h55m,
  # the worst deploy day this ledger has recorded — read 7.03% on the settled
  # basis, and ordinary days sit below that. 25% is therefore comfortably above
  # the noise floor AND above a bad day: it fires on a fleet where one settled
  # deploy in four is dying, which is not a shape this ledger has ever recorded
  # as normal. It is deliberately NOT tuned to fire on 08-08 — an alert that
  # would have fired on the worst day already on record is an alert with no
  # margin, and the epic's own baseline is the evidence.
  @alert_pct 25.0

  # HOW MANY CONSECUTIVE RED READINGS BEFORE ANYTHING IS SENT. Three hourly
  # ticks — the same shape as `Registry`'s `@default_health_down_after_count`
  # consecutive-miss threshold and the webhook auto-disable counter, which are
  # the two working consecutive-failure precedents in this codebase.
  #
  # It is the second half of the volume argument. A rolling 24h window keyed on
  # a single tick would re-fire hourly for as long as the incident's rows stay
  # inside the door — up to 24 emails for one incident. Three ticks plus the
  # `alerted_at` latch makes an incident of ANY length exactly one email.
  @consecutive_ticks 3

  @type verdict :: :red | :clear | :unmeasured

  @doc "The settled-basis failure percentage at or above which a reading is RED."
  @spec alert_pct() :: float()
  def alert_pct, do: @alert_pct

  @doc "Consecutive red readings required before a notice is sent."
  @spec consecutive_ticks() :: pos_integer()
  def consecutive_ticks, do: @consecutive_ticks

  @doc "The label of the `DigestEmail` door this verdict is taken over."
  @spec window_label() :: String.t()
  def window_label, do: @window_label

  @doc """
  The window this verdict reads, or `nil` when the reading has none — an
  unmeasured read, a site-less team, or a `deploy_health/1` shape whose doors do
  not include `window_label/0`.
  """
  @spec window(map()) :: map() | nil
  def window(%{unmeasured: true}), do: nil
  def window(%{no_sites: true}), do: nil

  def window(%{windows: windows}) when is_list(windows),
    do: Enum.find(windows, &(&1.label == @window_label))

  def window(_health), do: nil

  @doc """
  The verdict for one `DigestEmail.deploy_health/1` reading.

  `:unmeasured` for every absence — no window, an empty door, a REFUSED rate
  node (sample below `DeployLedger.min_sample/0`), or a node carrying no
  percentage. `:red` when the settled-basis percentage is at or above
  `alert_pct/0`, `:clear` below it.
  """
  @spec verdict(map()) :: verdict()
  def verdict(health) do
    case rate_node(health) do
      %{refused: false, pct: pct} when is_number(pct) ->
        if pct >= @alert_pct, do: :red, else: :clear

      _absent_or_refused ->
        :unmeasured
    end
  end

  @doc """
  The settled-basis rate node behind the verdict, or `nil`. The node carries its
  own denominator (`sample`), numerator and `min_sample`, so every caller that
  prints a percentage has the volume in the same map.
  """
  @spec rate_node(map()) :: map() | nil
  def rate_node(health) do
    case window(health) do
      %{terminal_rate: %{} = node} -> node
      _none -> nil
    end
  end

  @doc """
  Build (never send) the notice for one recipient.

  The subject carries the percentage AND its denominator, because a subject line
  is the part of an alert most likely to be read alone.
  """
  @spec build(map(), non_neg_integer(), String.t()) :: Swoosh.Email.t()
  def build(health, consecutive, recipient) when is_binary(recipient) do
    new()
    |> to(recipient)
    |> from(Mailer.from())
    |> subject(subject(health))
    |> text_body(body(health, consecutive))
  end

  @doc "The subject line: the rate, its volume, and the window it was taken over."
  @spec subject(map()) :: String.t()
  def subject(health) do
    node = rate_node(health) || %{}
    pct = Map.get(node, :pct)
    sample = Map.get(node, :sample, 0)
    numerator = Map.get(node, :numerator, 0)

    "Barkpark deploy failure RATE: #{format_pct(pct)} of settled deploys " <>
      "(#{numerator} of #{sample}) over the #{@window_label}"
  end

  @doc """
  The notice body.

  It says four things and nothing else: what the rate is on BOTH bases with both
  denominators (D525), how long it has stood there, what this email is NOT (one
  per deployment), and how to make it stop.
  """
  @spec body(map(), non_neg_integer()) :: String.t()
  def body(health, consecutive) do
    w = window(health) || %{}
    settled = Map.get(w, :terminal_rate)
    attempted = Map.get(w, :rate)

    """
    Barkpark deploy failure rate — this team's own sites.

    #{basis_line("Settled basis", settled, "settled")}
    #{basis_line("Attempted basis", attempted, "attempted")}

    Door: #{Map.get(w, :door, 0)} attempted, of which #{Map.get(w, :deferred, 0)} deferred by a busy box.
    Window: #{span(w)} (pinned at read time; both bounds explicit).
    Standing: #{consecutive} consecutive hourly readings at or above #{format_pct(@alert_pct)} on the settled basis.

    WHY THE SETTLED BASIS DECIDES. The attempted denominator counts deferrals — a
    box saying "not now" — and a deferral is a wait, not an outcome. Capacity
    pressure raises deferrals, which lowers the attempted percentage with no change
    in reliability, so an alert keyed on it goes quiet exactly when the platform is
    most congested. Both numbers are printed above; only the settled one fired this.

    A RATE REFUSES ITSELF BELOW n = #{DeployLedger.min_sample()}. This notice cannot be sent from a
    sample smaller than that: the rate node arrives refused and the reading is
    recorded as UNMEASURED, never as healthy.

    THIS IS NOT ONE EMAIL PER FAILED DEPLOYMENT. It is one email per episode: the
    rate must stand red for #{@consecutive_ticks} consecutive hourly readings before anything is
    sent, and nothing further is sent until the rate comes back down. Per-deployment
    alerts are the separate `deployment_failed` channel and are unchanged by this.

    TO STOP THESE. This notice rides the team's `deployment_failed` toggle — the
    same subject, the same switch. Turn that off (or `alerts_enabled` off) in the
    console's notification settings and it stops, with no new checkbox to find.

    This is an automated operator notice from Barkpark Cloud.\
    """
  end

  ## ── Rendering ────────────────────────────────────────────────────────────

  # ONE BASIS, and it can never print a bare percentage: either the number WITH
  # its denominator, or the node's own refusal reason WITH the counts that
  # survive it.
  defp basis_line(label, %{refused: true} = node, _basis) do
    "#{label}: UNMEASURED — #{Map.get(node, :reason, "the rate node refused")} " <>
      "(#{Map.get(node, :numerator, 0)} failed)."
  end

  defp basis_line(label, %{pct: pct, sample: sample, numerator: numerator}, basis)
       when is_number(pct) do
    "#{label}: #{format_pct(pct)} failed (#{numerator} of #{sample} #{basis})."
  end

  defp basis_line(label, _node, _basis),
    do: "#{label}: UNMEASURED — no rate node was returned for this window."

  defp format_pct(nil), do: "UNMEASURED"
  defp format_pct(pct) when is_number(pct), do: "#{pct}%"

  defp span(%{from: %DateTime{} = from, to: %DateTime{} = to}),
    do: "#{format_ts(from)} to #{format_ts(to)}"

  defp span(_w), do: "unknown"

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
