defmodule BarkparkCloud.Notifications.DigestEmail do
  @moduledoc """
  isu-w5 — builds the daily FLEET-UPDATE digest email: one plain-text operator
  report of where every managed instance stands against the newest release the
  fleet has seen. This is the "from nag to product" push — the release curator's
  daily judgment (a draft GitHub Release + a run log) becomes something a human
  passively RECEIVES instead of having to go look for.

  It is NOT a gui-premium "email type" (that system renders PortableDoc blocks
  and never SENDS). It is a transactional-style plain-text send: this module only
  RENDERS a `%Swoosh.Email{}` from fleet rows — `Notifications.deliver_fleet_digest/1`
  resolves the operator recipients and delivers over the platform `Mailer`.

  Truth-only inputs: every value comes from columns the fleet already polls
  (`update_state` / `update_running_release` / `update_latest_release` /
  `update_checked_at` from isu-6, plus `autoupdate_enabled` / `autoupdate_paused` /
  `pinned_release` from isu-w4, plus `commit_ancestry` / `commit_distance` /
  `commit_distance_checked_at` from deploy-reliability W21). It NEVER calls
  GitHub — "latest available" is simply the max `update_latest_release` across
  rows, the shared release fact the curator and the fleet both key off, surfaced
  through data already on hand.

  WHY THE COUNTS ARE NOT `update_state` (dr-w25-s6). `update_state` mirrors the
  instance's OWN release-tag self-grade, and the fleet's tag has not moved off
  `0.2.25` in ~2,500 builds — so drift WITHIN a release is invisible to it by
  construction, and five prod boxes sitting 1 / 268 / 633 / 927 / 2,509 commits
  behind `main` were all counted `current` in this email's subject line. The
  control plane's own measurement (`commit_ancestry`, from
  `BarkparkCloud.GitHub.CommitDistance`) decides the rung instead, and it decides
  it in ALL THREE places a human reads: the counts, the subject, and the per-box
  row.

  The rungs, and what each refuses to launder:

    * `behind` — measured missing commits, OR a box whose commit matches `main`
      while its own release self-report says `behind`. A measured-behind box is
      never `current`, whatever it says about itself.
    * `diverged` / `ahead of main` — their OWN words. Neither is "current" (the
      code is not `main`'s) and neither is "behind" (nothing is missing).
    * `unmeasured` — `commit_ancestry` NULL or `"unknown"` (agent reported no
      commit, an unknown sha, a rate-limit refusal). UNMEASURED is a rung of its
      own with a NAMED REASON, never folded into `current` and never into
      `behind`: a 0 in either bucket would be exactly the unearned green this
      slice removed.

  Every distance is rendered WITH its `commit_distance_checked_at` — measured at
  a time, never a constant (the headline moved 2,493 -> 2,509 between two
  measurements of the same box).

  `base_email/3` in `Notifications.Transactional` is private, so this module
  builds the `%Swoosh.Email{}` with the same four-line Swoosh pattern
  `Notifications.EventEmail` uses (`new/0 |> to |> from(Mailer.from) |> subject |>
  text_body`) — one platform From, plain text, no HTML polish (YAGNI).

  ## dr-w28-s5 — THE DIGEST THAT ARRIVES NAMES DEPLOY HEALTH, FOR THE TEAM'S OWN SITES

  This email reached a human for the first time in its recorded life at
  2026-08-09T06:00:00Z (four `notification_deliveries` rows, `event=fleet_digest`,
  `status=sent`). dr-w19-s5 fixed the ADDRESS and said out loud that it had not
  fixed the PAYLOAD: the summary above carries RELEASE FRESHNESS ONLY, so the
  first digest anybody ever received told four people nothing whatsoever about
  their deploy failures. `deploy_health/1` is the payload half.

  What the block is allowed to say, and the rules are binding:

    * **IT IS SCOPED TO THE RECIPIENT'S OWN SITES, ALWAYS.** The digest is
      delivered PER TEAM precisely so nobody learns of an instance they could
      not already read through their own team-scoped lists — and a fleet-wide
      deploy total inside a per-team email breaks that rule just as surely as a
      named league table would. Deploy volume IS platform information: the
      06:00Z send reached three teams, two of which own ZERO sites, and a
      fleet-wide reading would have told them how much the platform deploys and
      how often it fails. So `deploy_health/1` REQUIRES `:site_ids` and a caller
      that supplies none gets UNMEASURED rather than the fleet.
    * **NO SITES IS NOT NO ROWS.** A team that owns no sites has an empty window
      because it owns nothing, not because deploys stopped. `DeployLedger.census/3`
      deliberately refuses to collapse `nil` (unscoped) into `[]` (no sites)
      (`scope_to_sites/2`), and this block refuses to collapse the two REASONS a
      window can be empty for exactly the same reason: rendering "a window with
      nothing in it" at a site-less team is a false alarm delivered every morning.
    * **DERIVED AT RENDER TIME, NEVER BAKED.** Every number comes from
      `DeployLedger.census/3` over a window pinned at send time. No constant in
      this module is a measurement, and no measurement outlives the send that
      took it.
    * **EVERY RATE PRINTS BOTH BASES AND ITS DEFERRED POPULATION.** A failure
      percentage over the attempted door is unreadable without the deferral mass
      inside that door — a box refusing a slot is the platform working as
      designed, and the two windows disagree by an order of magnitude about how
      much of the door it is. So the line is always
      `<door> attempted, of which <deferred> deferred … — <pct> failed on
      attempted (…); <pct> failed on settled (…)`, and neither basis can be
      rendered on its own (dr-w31/D525). A deferral is a WAIT, not an outcome:
      capacity pressure raises deferrals, which lowers the ATTEMPTED-basis
      percentage with no change in reliability at all, so a digest quoting that
      number alone can report a repair nobody performed. The SETTLED basis
      (`failed + live`) cannot be moved that way, and it stands beside its twin
      precisely so a reader can see the gap the deferrals opened.
    * **UNMEASURED RENDERS AS UNMEASURED.** A refused rate (sample below
      `DeployLedger.min_sample/0`, or a window straddling the deferred-status
      vocabulary boundary), a window with no rows at all, or a ledger this
      process could not read, all render the word UNMEASURED with the reason
      that produced it. Never 0%, never "healthy" — an unmeasured reading
      arriving as a green one is the exact defect this epic exists to remove.
      Expect a small team to fall below `min_sample` and render the
      counts-intact refusal: that is the honest answer, not a regression.
    * **NO LIFETIME RATE.** The all-time numerator's honest freeze point is
      2026-08-08T14:55:28.776961 at 18,640, which is not the instant anybody
      would read it as, so the digest reports only windows it pins itself.
  """
  import Swoosh.Email

  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Mailer
  alias BarkparkCloud.Registry.Barkpark

  # The doors the digest reports, in the order a human reads them: what just
  # happened, then whether it is normal. TWO windows and not one, because a
  # single door cannot tell a bad day from a bad week — and on the corpus that
  # motivated this block they disagreed by an order of magnitude (a 24h door of
  # 852 against a 7d door of 9,156, with wildly different deferral shares).
  @deploy_windows [{"last 24h", 86_400}, {"last 7d", 604_800}]

  # THE REACH LIMIT, DERIVED FROM THE DOORS THEMSELVES so the disclosure can
  # never drift from what is actually reported: whatever the widest door is, a
  # row older than it was never in the population, and a coverage zero over a
  # bounded window is therefore not a clean bill for the fleet.
  @widest_window_label @deploy_windows |> Enum.max_by(&elem(&1, 1)) |> elem(0)

  @typedoc """
  One box's freshness rung, decided by the control plane's OWN commit
  measurement rather than the box's release-tag self-report.
  """
  @type freshness :: :current | :behind | :diverged | :ahead | :unmeasured

  @typedoc """
  One deploy door, as the digest reports it: the attempted population, the
  deferral mass INSIDE that population, and the failure rate on BOTH bases —
  all of them always travelling together so a percentage can never be printed
  alone, and neither basis can be quoted without its twin.

  TWO RATES AND TWO DENOMINATORS (dr-w31/D525). `rate` is the ATTEMPTED-basis
  node (`census.failure_rate`, denominator `door`, deferrals included);
  `terminal_rate` is the SETTLED-basis node (`census.terminal_failure_rate`,
  denominator `settled = failed + live`). They share a numerator and differ by
  exactly the deferral mass, which is why `deferred` rides beside them: a
  deferral is a WAIT, not an outcome, so pressure that raises deferrals lowers
  `rate` while `terminal_rate` does not move. A digest that printed only `rate`
  would let a morning email report a fleet getting better because it waited more.
  """
  @type deploy_window :: %{
          label: String.t(),
          from: DateTime.t(),
          to: DateTime.t(),
          door: non_neg_integer(),
          deferred: non_neg_integer(),
          failed: non_neg_integer(),
          settled: non_neg_integer(),
          rate: map(),
          terminal_rate: map()
        }

  @typedoc """
  The deploy-health reading for ONE team's sites, or a NAMED refusal to have one.

  `no_sites: true` is its own fact and not a flavour of `unmeasured`: the team
  owns nothing that could have deployed, so there is no reading to take and
  nothing is being withheld. `unmeasured: true` means this send could not take a
  reading it should have been able to take, and `windows` is empty; an individual
  window can also be unmeasured on its own (refused rate, or no rows).
  """
  @type deploy_health :: %{
          windows: [deploy_window()],
          measured_at: DateTime.t() | nil,
          unmeasured: boolean(),
          no_sites: boolean(),
          reason: String.t() | nil
        }

  @typedoc "The pre-computed fleet roll-up the subject + body render from."
  @type summary :: %{
          total: non_neg_integer(),
          current: non_neg_integer(),
          behind: non_neg_integer(),
          diverged: non_neg_integer(),
          ahead: non_neg_integer(),
          unmeasured: non_neg_integer(),
          paused: non_neg_integer(),
          latest: String.t() | nil,
          deploy: deploy_health(),
          instances: [Barkpark.t()]
        }

  @doc """
  Roll the fleet rows up into the counts the digest reports. Pure — no DB, no
  clock — so the subject/body rendering is fully testable from fixture rows.

    * `current` / `behind` / `diverged` / `ahead` / `unmeasured` — instances at
      each `freshness/1` rung. These are MEASURED rungs (`commit_ancestry`), not
      `update_state`: a box 2,509 commits behind `main` is `behind` here even
      though it grades itself `current`;
    * `paused` — instances with `autoupdate_paused` set (the operator escape hatch);
    * `latest` — the newest `update_latest_release` seen across the fleet
      (semver-aware, `nil` when no row has reported one yet).

  The five rungs partition the fleet: `current + behind + diverged + ahead +
  unmeasured == total`, always. `paused` is a policy flag that cuts across them.

    * `deploy` — the deploy-health reading for the recipient team's own sites
      (dr-w28-s5), passed IN as `:deploy` rather than measured here so this
      function stays pure. A caller that supplies nothing gets an UNMEASURED
      reading with that fact as its reason — the omission surfaces in the
      delivered email instead of rendering as a team with no deploy failures.
      `Notifications.deliver_fleet_digest/1` supplies one per team from
      `deploy_health/1`.
  """
  @spec summary([Barkpark.t()], keyword()) :: summary()
  def summary(barkparks, opts \\ []) when is_list(barkparks) do
    counts = Enum.frequencies_by(barkparks, &freshness/1)

    %{
      total: length(barkparks),
      current: Map.get(counts, :current, 0),
      behind: Map.get(counts, :behind, 0),
      diverged: Map.get(counts, :diverged, 0),
      ahead: Map.get(counts, :ahead, 0),
      unmeasured: Map.get(counts, :unmeasured, 0),
      paused: Enum.count(barkparks, & &1.autoupdate_paused),
      latest: latest_release(barkparks),
      deploy:
        Keyword.get(
          opts,
          :deploy,
          unmeasured_deploy(nil, "this send supplied no deploy-ledger reading")
        ),
      instances: barkparks
    }
  end

  @doc """
  READ the deploy ledger for ONE TEAM'S OWN SITES over the windows this digest
  reports — the one impure call in this module, kept here (rather than in the
  caller) so the measurement and the sentences that render it live in the same
  file and cannot drift.

  `:site_ids` is REQUIRED and is the whole tenancy story. It is handed straight
  to `DeployLedger.census/3`, which scopes the SOURCE query rather than
  post-filtering a rendered node, so every total above the site list is narrowed
  too. Three values, three different facts, and none of them collapses into
  another:

    * a list of ids — measure those sites;
    * `[]` — the team owns NO sites. Not a measurement failure and not an empty
      window: there was nothing here to deploy. Rendered as its own sentence
      (`no_sites: true`), because the empty-window sentence would be a false
      alarm delivered to a site-less team every morning;
    * absent, or `{:error, reason}` from a caller whose site lookup failed —
      UNMEASURED. It is never read as "the whole fleet": a fleet-wide reading in
      a per-team email is the cross-team disclosure the per-team partition
      exists to prevent, so the fail-closed direction is to say nothing.

  Both bounds of every window are PINNED at `:now` (defaults to
  `DateTime.utc_now/0`) and handed to `DeployLedger.census/3` explicitly: a
  floating "now minus 24h" cannot be compared against itself tomorrow, and two
  unpinned windows are how a volume collapse gets read as a repair (D3).

  IT CANNOT BREAK THE SEND IT DESCRIBES. A ledger read that raises, or that
  EXITS (a `DBConnection` timeout is an exit, not an exception, and this control
  plane has produced them under swap pressure), yields an UNMEASURED reading
  carrying the failure's own words — the digest still goes out, and it goes out
  saying it does not know rather than saying nothing is wrong.
  """
  @spec deploy_health(keyword()) :: deploy_health()
  def deploy_health(opts \\ []) do
    now =
      opts
      |> Keyword.get(:now, DateTime.utc_now())
      |> DateTime.truncate(:second)

    case Keyword.get(opts, :site_ids, :no_scope) do
      # `nil` is `census/3`'s word for UNSCOPED — the fleet. It is matched HERE
      # and refused, alongside the absent option, so no path through this module
      # can reach a fleet-wide read: a caller who fumbled the scope gets the
      # word UNMEASURED rather than every other team's numbers.
      scope when scope in [:no_scope, nil] ->
        unmeasured_deploy(now, "this send supplied no team scope, so no reading was taken")

      {:error, reason} ->
        unmeasured_deploy(now, "this team's sites could not be listed: #{reason}")

      [] ->
        %{
          windows: [],
          measured_at: now,
          unmeasured: false,
          no_sites: true,
          reason: "this team owns no sites"
        }

      site_ids when is_list(site_ids) ->
        measure_deploy(site_ids, now)
    end
  end

  defp measure_deploy(site_ids, now) do
    %{
      windows: Enum.map(@deploy_windows, &window_health(&1, now, site_ids)),
      measured_at: now,
      unmeasured: false,
      no_sites: false,
      reason: nil
    }
  rescue
    e -> unmeasured_deploy(now, "the deploy ledger could not be read: #{Exception.message(e)}")
  catch
    :exit, reason -> unmeasured_deploy(now, "the deploy ledger read exited: #{inspect(reason)}")
  end

  defp window_health({label, seconds}, now, site_ids) do
    from = DateTime.add(now, -seconds, :second)

    # `site_limit: 0` because this block reports a RATE over the team's own
    # sites, never a per-site league table: the counts and percentages name
    # nobody, and the population is already narrowed to sites this recipient can
    # read by name elsewhere.
    census = DeployLedger.census(from, now, site_ids: site_ids, site_limit: 0)

    %{
      label: label,
      from: from,
      to: now,
      door: census.volume,
      deferred: Enum.reduce(census.deferred, 0, &(&1.count + &2)),
      failed: census.failed,
      # THE SETTLED DENOMINATOR, taken from the census's OWN counts and never
      # re-derived as `door - deferred`: that subtraction folds in-flight,
      # cancelled and residual rows into the settled cohort, which is the same
      # forbidden subtraction `census/3` refuses one level up (D257).
      settled: census.failed + census.live,
      rate: census.failure_rate,
      # THE SAME NUMERATOR OVER THE SETTLED DENOMINATOR (dr-w31/D525). Carried
      # BESIDE `rate`, never instead of it: both bases print or neither does.
      terminal_rate: census.terminal_failure_rate,
      # The wait was ALREADY in this census and was being thrown away here: the
      # deferral count answers "how often did a box say not now", and only the
      # wait answers "and how long did that cost the site". One key, no second
      # `census/3` call site.
      wait: census.deferral_wait,
      # THE COVERAGE PARTITION (dr-w32-s3). The wait above is a clock over the
      # DEFERRED rows only; this is the same clock's verdict over the deferred
      # AND the failed-terminating cohorts — "is any of this team's sites
      # sitting there un-rebuilt". It rides the digest because the digest
      # already reaches a human every morning: the gauge that decides whether
      # this epic can wind down must not need somebody to go and look.
      coverage: census.coverage_cohorts
    }
  end

  defp unmeasured_deploy(measured_at, reason),
    do: %{
      windows: [],
      measured_at: measured_at,
      unmeasured: true,
      no_sites: false,
      reason: reason
    }

  @doc """
  The freshness rung of ONE instance — the single decision the counts, the
  subject and the per-box row all read, so no two of them can disagree.

  `commit_ancestry` (the control plane's own GitHub compare verdict) decides.
  `update_state` (the box's release-tag self-grade) can only ever make the
  verdict WORSE: a box whose commit matches `main` while its own tag says
  `behind` is reported `behind`, never `current`. A NULL or `"unknown"` ancestry
  is `:unmeasured` — it is never rounded into either bucket, whatever the box
  says about itself.
  """
  @spec freshness(Barkpark.t()) :: freshness()
  def freshness(%Barkpark{} = bp) do
    case present(bp.commit_ancestry) do
      "behind" -> :behind
      "diverged" -> :diverged
      "ahead_of_main" -> :ahead
      "current" -> if present(bp.update_state) == "behind", do: :behind, else: :current
      _ -> :unmeasured
    end
  end

  @doc """
  The digest subject line — the fleet health at a glance, on the MEASURED rungs.

  `current` / `behind` / `unmeasured` / `paused` are always present (a `0
  unmeasured` is itself the signal that the fleet is fully measured); `diverged`
  and `ahead of main` appear only when a box is actually on them.
  """
  @spec subject(summary()) :: String.t()
  def subject(%{} = s) do
    "Barkpark fleet digest — " <> Enum.join(count_words(s), " / ")
  end

  @doc """
  The plain-text digest body: a fleet header (counts + latest available release)
  then one honest line per instance (name, running -> latest, state, pin/pause
  flags, last checked). An empty fleet renders a clear "no instances" line rather
  than a bare header.
  """
  @spec body(summary()) :: String.t()
  def body(%{instances: []} = s) do
    """
    #{header(s)}

    #{deploy_block(s)}

    No instances are registered yet — nothing to report.

    #{footer()}
    """
  end

  def body(%{instances: instances} = s) do
    lines = Enum.map_join(instances, "\n", &instance_line/1)

    """
    #{header(s)}

    #{deploy_block(s)}

    Instances:
    #{lines}

    #{footer()}
    """
  end

  @doc """
  Build (but do not send) the digest `%Swoosh.Email{}` for one operator
  `recipient` from a pre-computed `summary`. Separated from delivery so a test
  can inspect the struct and so every recipient shares one rendering.
  """
  @spec build(summary(), String.t()) :: Swoosh.Email.t()
  def build(summary, recipient) when is_binary(recipient) do
    new()
    |> to(recipient)
    |> from(Mailer.from())
    |> subject(subject(summary))
    |> text_body(body(summary))
  end

  ## ── Rendering helpers ────────────────────────────────────────────────────

  defp header(%{total: total, latest: latest} = s) do
    fleet =
      case total do
        0 ->
          "Fleet: 0 instances."

        _ ->
          "Fleet: #{total} #{pluralize(total, "instance")} — " <>
            Enum.join(count_words(s), ", ") <> "."
      end

    """
    Barkpark fleet — daily update digest.

    #{fleet}
    Latest available release: #{latest || "unknown"}\
    """
  end

  # The count vocabulary the subject and the header share, so the two can never
  # drift apart. `diverged` / `ahead of main` earn their own word (neither is
  # "current" and neither is "behind") but only appear when a box is on them;
  # `unmeasured` is ALWAYS shown — hiding it at 0 would make its absence
  # ambiguous with "we never asked".
  defp count_words(%{current: c, behind: b, paused: p} = s) do
    diverged = Map.get(s, :diverged, 0)
    ahead = Map.get(s, :ahead, 0)

    ["#{c} current", "#{b} behind"] ++
      if(diverged > 0, do: ["#{diverged} diverged"], else: []) ++
      if(ahead > 0, do: ["#{ahead} ahead of main"], else: []) ++
      ["#{Map.get(s, :unmeasured, 0)} unmeasured", "#{p} paused"]
  end

  # THE DEPLOY-HEALTH BLOCK (dr-w28-s5). FIVE shapes, and three of them are the
  # word UNMEASURED — because every way this reading can be absent is a way the
  # old payload was silently reassuring. A missing `:deploy` key is the fourth
  # and is treated the same as an explicit refusal: a summary map built without
  # one has not measured anything, whoever built it.
  #
  # THE FIFTH IS NOT A REFUSAL AT ALL, and it comes first on purpose. A team
  # that owns no sites is not an unmeasured team — it is a team with nothing to
  # measure, and telling it every morning that a window had nothing in it would
  # be a false alarm dressed as honesty. It gets its own sentence.
  defp deploy_block(%{deploy: %{no_sites: true}}) do
    "Deploy health: this team owns no sites, so it ran no deploys — " <>
      "nothing was measured here and nothing is being withheld."
  end

  defp deploy_block(%{deploy: %{unmeasured: true, reason: reason}}),
    do: "Deploy health: UNMEASURED — #{reason}."

  defp deploy_block(%{deploy: %{windows: []}}),
    do: "Deploy health: UNMEASURED — the ledger returned no windows to report."

  defp deploy_block(%{deploy: %{windows: windows} = d}) do
    "Deploy health for this team's sites (control-plane deploy ledger, read " <>
      "#{format_ts(d.measured_at)}):\n" <>
      Enum.map_join(windows, "\n", &deploy_line/1) <> "\n" <> reach_line()
  end

  defp deploy_block(_s),
    do: "Deploy health: UNMEASURED — this send supplied no deploy-ledger reading."

  # ONE DOOR. The attempted population and the deferral mass inside it are
  # printed BEFORE the percentage and on the same line, so the rate cannot be
  # quoted without them: a busy box refusing a slot is the platform working as
  # designed, and it was 66% of one of these doors and 6% of the other.
  #
  # The empty-window sentence says "this team's sites" out loud, because the
  # reading IS team-scoped and a headline that says "fleet" over a scoped read is
  # the defect `dr-w18-bl-census-headline-still-says-fleet` already names on
  # another surface. A team that owns no sites never reaches this line at all.
  defp deploy_line(%{door: 0} = w) do
    "  #{w.label} (#{span(w)}): UNMEASURED — no deploy rows at all in this window " <>
      "for this team's sites. A window with nothing in it is not a clean bill of health."
  end

  defp deploy_line(w) do
    "  #{w.label} (#{span(w)}): #{number(w.door)} attempted, of which " <>
      "#{number(w.deferred)} deferred by a busy box — #{rate_clause(w)}. #{wait_clause(w)}. " <>
      "#{coverage_clause(w)}."
  end

  # BOTH BASES OR NEITHER (dr-w31/D525), in ONE clause that cannot emit half of
  # itself. The two arms below are rendered by the SAME function over the SAME
  # numerator, so there is no code path on which a reader receives one
  # percentage and no second denominator: `basis_clause/4` prints its own
  # UNMEASURED sentence when its node refuses or is absent, and it is called
  # unconditionally for both bases.
  #
  # WHY IT IS NOT COSMETIC (this is dr-w29's dilution, in the surface that
  # reaches a human every morning). The attempted door INCLUDES deferrals; the
  # settled door does not. Capacity pressure raises deferrals, which lowers the
  # attempted-basis percentage with zero change in reliability — so the
  # attempted number alone can report a repair that the settled number,
  # standing right beside it, refuses to confirm.
  defp rate_clause(w) do
    attempted = basis_clause(Map.get(w, :rate), w.failed, w.door, "attempted")
    settled = basis_clause(Map.get(w, :terminal_rate), w.failed, Map.get(w, :settled, 0), "settled")

    attempted <> "; " <> settled
  end

  # ONE basis, rendered with its OWN denominator beside it — three endings and
  # not one of them is a bare percentage.
  #
  #   * the node REFUSES: its reason verbatim, and the counts, which survive a
  #     refusal because they are real rows (exactly as `DeployLedger.census/3`
  #     withholds the ratio and keeps the counts one level up);
  #   * the node is ABSENT or a shape this renderer does not understand: also
  #     UNMEASURED, never a percentage. This is the arm a control plane older
  #     than `terminal_failure_rate` lands on, and it must still print, because
  #     an omitted settled line reads as "there is only one denominator";
  #   * the node has a percentage: the percentage, its numerator and its
  #     denominator, together.
  defp basis_clause(%{refused: true, reason: reason}, failed, denom, label),
    do:
      "failure rate on #{label} UNMEASURED (#{reason}); #{number(failed)} of " <>
        "#{number(denom)} #{label} are settled failures"

  defp basis_clause(%{pct: pct}, failed, denom, label) when is_number(pct),
    do: "#{pct}% failed on #{label} (#{number(failed)} of #{number(denom)} #{label})"

  defp basis_clause(_node, failed, denom, label),
    do:
      "failure rate on #{label} UNMEASURED (the ledger returned no usable rate); " <>
        "#{number(failed)} of #{number(denom)} #{label} are settled failures"

  # THE COST OF A DEFERRAL, in the same shape as the rate: the number when the
  # census can name one, the census's OWN refusal reason when it cannot, and the
  # population beside it either way. `min_sample` is 200 over a TEAM's sites, so
  # the refusal is the ordinary reading for a small team and it must read as a
  # withheld ratio, never as "no wait" and never as an empty clause.
  defp wait_clause(%{wait: %{max: %{refused: true, reason: reason}, population: %{} = pop}}) do
    "Deferral wait UNMEASURED (#{reason}); #{wait_population(pop)}"
  end

  defp wait_clause(%{wait: %{max: %{seconds: seconds}, population: %{} = pop}})
       when is_number(seconds) do
    "The slowest of those deferrals waited #{duration(seconds)} for a box; #{wait_population(pop)}"
  end

  # A wait node this renderer does not understand renders as UNMEASURED, for the
  # same reason `rate_clause/1` does: the one direction this block may never
  # fail in is a reassuring number nobody measured.
  defp wait_clause(_),
    do: "Deferral wait UNMEASURED (the ledger returned no usable wait)"

  # The sample and what it is a sample OF, so a wait can never be quoted without
  # the rows it excluded — a fast max over 3 of 500 covered rows is not a fast
  # platform.
  defp wait_population(%{deferred: deferred, covered: covered, pending: pending}) do
    "#{number(covered)} of #{number(deferred)} deferred rows have since rebuilt, " <>
      "#{number(pending)} are still waiting"
  end

  defp wait_population(_), do: "its deferral population was not reported"

  # THE COVERAGE PARTITION, IN THE SAME SHAPE AS THE RATE AND THE WAIT (dr-w32-s3):
  # the reading when the census can name one, the word UNMEASURED when it cannot,
  # and never an empty clause.
  #
  # THE WORDING IS THE FEATURE (D478). COVERED means THE SITE HAS SINCE REBUILT.
  # It does NOT mean the reader's edit shipped, and this sentence says the first
  # thing out loud precisely so nobody reads the second one into it. The window
  # is named INSIDE the clause and not left to the line prefix, because this
  # sentence gets quoted on its own.
  defp coverage_clause(%{coverage: %{cohorts: [_ | _] = cohorts, maturity_seconds: maturity}} = w) do
    "Coverage over #{w.label} (COVERED means the site has since rebuilt, not that an edit " <>
      "of yours shipped): " <> Enum.map_join(cohorts, "; ", &cohort_clause(&1, maturity))
  end

  defp coverage_clause(_),
    do: "Coverage UNMEASURED (the ledger returned no coverage cohorts)"

  # THE EMAIL'S OWN REACH, SAID OUT LOUD, ONCE (dr-w33-s3; moved out of
  # `coverage_clause/1` at review). Every number in this block is counted inside
  # a bounded door, so a row older than the widest one this email reports was
  # never in the population being judged — it is OUTSIDE it, not covered. Without
  # this sentence a `0 still not after 24.0h` reads as a clean bill of health for
  # the fleet, when it can equally mean the stuck rows are simply older than the
  # door: the epic's own five never-covered rows are 26 days old and invisible to
  # BOTH doors.
  #
  # It lives on the BLOCK, not on each window line, for two reasons. It is a
  # property of the email rather than of a line, so repeating it verbatim under
  # every door is noise in a human's inbox; and per-line it would vanish entirely
  # whenever every window fell to the coverage-UNMEASURED arm — a disclosure that
  # disappears exactly when the numbers get less trustworthy is fail-open.
  defp reach_line do
    "  Reach limit: #{@widest_window_label} is the widest window this email reports, so a row " <>
      "older than that is OUTSIDE this population rather than covered by it."
  end

  # A cohort with no rows says so. Zero of zero is not 100% coverage and must
  # never render as a percentage.
  defp cohort_clause(%{cohort: cohort, population: 0}, _maturity),
    do: "no #{cohort} rows"

  # EVERY COUNT THIS SENTENCE PRINTS IS NAMED IN THE HEAD, so a cohort missing
  # one of them falls to the refusal clause below instead of raising a KeyError
  # inside the interpolation. The daily digest is the carrier this epic's
  # wind-down reading rides on; a shape it cannot read must cost that one clause,
  # never the whole morning email.
  defp cohort_clause(
         %{cohort: cohort, population: population, covered: covered, never_covered: never} = c,
         maturity
       ) do
    "#{number(covered)} of #{number(population)} #{cohort} rows have since been " <>
      "covered by a later live build, #{number(never)} still not after " <>
      "#{duration(maturity)}" <>
      cohort_tail(c) <> environment_clause(never, c)
  end

  defp cohort_clause(_c, _maturity), do: "a cohort the digest could not read"

  # WHICH ENVIRONMENTS THE NEVER-COVERED ROWS ARE IN (dr-w33-s3). The ledger has
  # always computed this split (`never_covered_by_environment`) and the digest
  # has always thrown it away, which is exactly the pooling the split exists to
  # refuse: a preview build with no successor is not a production site sitting
  # dark, and three real production rows must not hide inside a bigger, softer
  # number. Read with `Map.get/3` and filtered to readable entries for the same
  # reason the head above names every count it prints — an unreadable shape costs
  # this fragment, never the morning email.
  defp environment_clause(never, _c) when not (is_integer(never) and never > 0), do: ""

  defp environment_clause(_never, c) do
    c
    |> Map.get(:never_covered_by_environment, [])
    |> List.wrap()
    |> Enum.filter(fn
      %{environment: _, never_covered: n} -> is_integer(n) and n > 0
      _ -> false
    end)
    |> case do
      [] -> ""
      entries -> " — of those, " <> Enum.map_join(entries, ", ", &environment_part/1)
    end
  end

  # A row whose environment the ledger could not name is still a never-covered
  # row: it is reported as unnamed rather than dropped, because a dropped row
  # would make the parts sum to less than the count they are splitting.
  defp environment_part(%{environment: environment, never_covered: n})
       when is_binary(environment) and environment != "",
       do: "#{number(n)} in #{environment}"

  defp environment_part(%{never_covered: n}), do: "#{number(n)} in an unnamed environment"

  # The two counts that are neither covered nor never-covered, stated only when
  # they exist: a row too young to judge is not a stuck site, and a row nobody
  # could classify is not a healthy one.
  defp cohort_tail(c) do
    parts =
      [
        {Map.get(c, :too_young, 0), "too young to judge"},
        {Map.get(c, :unreadable, 0), "unreadable"}
      ]
      |> Enum.filter(fn {n, _} -> is_integer(n) and n > 0 end)
      |> Enum.map(fn {n, what} -> "#{number(n)} #{what}" end)

    case parts do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  # Seconds are what the ledger measures; a human reads minutes and hours. One
  # decimal, never rounded to a whole unit — "0h" for a 4-minute wait would be a
  # different claim than the one measured.
  defp duration(seconds) when is_number(seconds) and seconds < 60,
    do: "#{one_decimal(seconds)}s"

  defp duration(seconds) when is_number(seconds) and seconds < 3600,
    do: "#{one_decimal(seconds / 60)}m"

  defp duration(seconds) when is_number(seconds), do: "#{one_decimal(seconds / 3600)}h"

  defp one_decimal(n), do: Float.round(n / 1, 1)

  defp span(%{from: from, to: to}), do: "#{format_ts(from)} to #{format_ts(to)}"

  # Thousands-grouped, because these doors run to five figures and `9156` reads
  # as a different order of magnitude than `9,156` at a glance.
  defp number(n) when is_integer(n) and n < 0, do: "-" <> number(-n)

  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp number(n), do: to_string(n)

  defp footer do
    "This is an automated operator digest from Barkpark Cloud."
  end

  # One instance's honest status line:
  #   - Name (slug): <running> -> <latest> | state: <measured rung>[ (release
  #     self-report: <state>)] | <commit distance, measured at a time>[ |
  #     <flags>] | checked <ts>
  defp instance_line(%Barkpark{} = bp) do
    running = present(bp.update_running_release) || present(bp.version) || "unknown"
    latest = present(bp.update_latest_release) || "unknown"

    "- #{bp.name} (#{bp.slug}): #{running} -> #{latest} | state: #{state_clause(bp)}" <>
      " | #{distance_clause(bp)}" <>
      flags_suffix(bp) <>
      " | checked #{format_ts(bp.update_checked_at)}"
  end

  # The rung a human reads on the row is the MEASURED one. The box's own
  # release-tag self-grade is still printed when it DISAGREES — that
  # disagreement is the whole finding ("current" on a box 2,509 commits behind),
  # and dropping it would hide which of the two producers is lying.
  defp state_clause(%Barkpark{} = bp) do
    rung = rung_word(freshness(bp))
    self_report = present(bp.update_state)

    if is_nil(self_report) or self_report == rung do
      rung
    else
      "#{rung} (release self-report: #{self_report})"
    end
  end

  defp rung_word(:current), do: "current"
  defp rung_word(:behind), do: "behind"
  defp rung_word(:diverged), do: "diverged"
  defp rung_word(:ahead), do: "ahead of main"
  defp rung_word(:unmeasured), do: "unmeasured"

  # The measured commit distance, ALWAYS carrying when it was measured — a
  # distance without its clock reads as a constant, and this one moved
  # 2,493 -> 2,509 between two measurements of the same box.
  defp distance_clause(%Barkpark{} = bp) do
    case freshness(bp) do
      # THE ONE RUNG THE MEASUREMENT DID NOT PRODUCE. `behind` is reachable two
      # ways: the compare found missing commits, or the compare found NONE and
      # the box's own release tag said `behind` anyway (the self-report can only
      # ever make the verdict worse). In the second case the measured distance is
      # genuinely 0, so rendering the plain "0 commits behind main" beside the
      # word `behind` reads as a contradiction and silently drops the only thing
      # that explains it. Name the producer instead.
      :behind when bp.commit_ancestry == "current" ->
        "0 commits behind main (#{measured_at(bp)}) — behind by its own release tag, not by commit"

      :behind ->
        "#{commits(bp.commit_distance)} behind main (#{measured_at(bp)})"

      :current ->
        "0 commits behind main (#{measured_at(bp)})"

      :ahead ->
        "#{commits(bp.commit_distance)} ahead of main (#{measured_at(bp)})"

      :diverged ->
        "diverged from main, #{commits(bp.commit_distance)} not on main (#{measured_at(bp)})"

      :unmeasured ->
        "commit distance unmeasured (#{unmeasured_reason(bp)})"
    end
  end

  defp commits(n) when is_integer(n), do: "#{n} #{pluralize(n, "commit")}"
  defp commits(_), do: "an unrecorded number of commits"

  defp measured_at(%Barkpark{commit_distance_checked_at: nil}),
    do: "measured at an unrecorded time"

  defp measured_at(%Barkpark{commit_distance_checked_at: ts}),
    do: "measured #{format_ts(ts)}"

  # UNMEASURED is only honest if it says WHY. Every arm names a real failure
  # mode `Registry.refresh_commit_distance/2` can land, and none of them is
  # allowed to round to 0 commits behind.
  defp unmeasured_reason(%Barkpark{} = bp) do
    case {present(bp.commit_ancestry), present(bp.git_commit)} do
      {nil, _} ->
        "never measured"

      {"unknown", nil} ->
        "instance has reported no commit; last asked #{format_ts(bp.commit_distance_checked_at)}"

      {"unknown", _} ->
        "no usable answer from the commit compare; last asked #{format_ts(bp.commit_distance_checked_at)}"

      {other, _} ->
        "unrecognized ancestry #{inspect(other)}; last asked #{format_ts(bp.commit_distance_checked_at)}"
    end
  end

  # The pin/pause/autoupdate-off flags an operator needs to read a row honestly.
  # Empty (no suffix) when the instance carries none.
  defp flags_suffix(%Barkpark{} = bp) do
    flags =
      [
        if(present(bp.pinned_release), do: "pinned=#{bp.pinned_release}"),
        if(bp.autoupdate_paused, do: "paused"),
        if(bp.autoupdate_enabled == false, do: "autoupdate off")
      ]
      |> Enum.reject(&is_nil/1)

    case flags do
      [] -> ""
      list -> " | " <> Enum.join(list, ", ")
    end
  end

  # The newest release across the fleet — semver-aware where the tags parse
  # (`v1.10.0` > `v1.9.0`, which a lexical max gets wrong), falling back to a
  # lexical compare for non-semver tags so a weird tag never crashes the digest.
  defp latest_release(barkparks) do
    barkparks
    |> Enum.map(& &1.update_latest_release)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.reduce(nil, fn tag, acc ->
      cond do
        is_nil(acc) -> tag
        release_gte?(tag, acc) -> tag
        true -> acc
      end
    end)
  end

  defp release_gte?(a, b) do
    case {parse_version(a), parse_version(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) != :lt
      _ -> a >= b
    end
  end

  defp parse_version(tag) when is_binary(tag) do
    tag |> String.trim_leading("v") |> Version.parse()
  end

  defp format_ts(nil), do: "never"
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v) when is_binary(v), do: v

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"
end
