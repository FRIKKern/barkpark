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

  ## dr-w27-s8 — THE DIGEST THAT ARRIVES NAMES DEPLOY HEALTH

  This email reached a human for the first time in its recorded life at
  2026-08-09T06:00:00Z (four `notification_deliveries` rows, `event=fleet_digest`,
  `status=sent`). dr-w19-s5 fixed the ADDRESS and said out loud that it had not
  fixed the PAYLOAD: the summary above carries RELEASE FRESHNESS ONLY, so the
  first digest anybody ever received told four people nothing whatsoever about
  the fleet's deploy failures. `deploy_health/1` is the payload half.

  What the block is allowed to say, and the rules are binding:

    * **DERIVED AT RENDER TIME, NEVER BAKED.** Every number comes from
      `DeployLedger.census/3` over a window pinned at send time. No constant in
      this module is a measurement, and no measurement outlives the send that
      took it.
    * **EVERY POST-DOOR RATE PRINTS ITS DEFERRED POPULATION BESIDE IT.** A
      failure percentage over the attempted door is unreadable without the
      deferral mass inside that door — a box refusing a slot is the fleet
      working as designed, and the two windows disagree by an order of magnitude
      about how much of the door it is. So the line is always
      `<door> attempted, of which <deferred> deferred … — <pct> failed`, and a
      rate cannot be rendered on its own.
    * **UNMEASURED RENDERS AS UNMEASURED.** A refused rate (sample below
      `DeployLedger.min_sample/0`, or a window straddling the deferred-status
      vocabulary boundary), a window with no rows at all, or a ledger this
      process could not read, all render the word UNMEASURED with the reason
      that produced it. Never 0%, never "healthy" — an unmeasured fleet reading
      as a green one is the exact defect this epic exists to remove.
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

  @typedoc """
  One box's freshness rung, decided by the control plane's OWN commit
  measurement rather than the box's release-tag self-report.
  """
  @type freshness :: :current | :behind | :diverged | :ahead | :unmeasured

  @typedoc """
  One deploy door, as the digest reports it: the attempted population, the
  deferral mass INSIDE that population, and the post-door failure rate — the
  three always travelling together so a percentage can never be printed alone.
  """
  @type deploy_window :: %{
          label: String.t(),
          from: DateTime.t(),
          to: DateTime.t(),
          door: non_neg_integer(),
          deferred: non_neg_integer(),
          failed: non_neg_integer(),
          rate: map()
        }

  @typedoc """
  The deploy-health reading, or a NAMED refusal to have one. `unmeasured: true`
  means this send could not read the ledger at all and `windows` is empty; an
  individual window can also be unmeasured on its own (refused rate, or no rows).
  """
  @type deploy_health :: %{
          windows: [deploy_window()],
          measured_at: DateTime.t() | nil,
          unmeasured: boolean(),
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

    * `deploy` — the deploy-health reading (dr-w27-s8), passed IN as `:deploy`
      rather than measured here so this function stays pure. A caller that
      supplies nothing gets an UNMEASURED reading with that fact as its reason —
      the omission surfaces in the delivered email instead of rendering as a
      fleet with no deploy failures. `Notifications.deliver_fleet_digest/1`
      supplies one from `deploy_health/1`.
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
  READ the deploy ledger for the windows this digest reports — the one impure
  call in this module, kept here (rather than in the caller) so the measurement
  and the sentences that render it live in the same file and cannot drift.

  Both bounds of every window are PINNED at `:now` (defaults to
  `DateTime.utc_now/0`) and handed to `DeployLedger.census/3` explicitly: a
  floating "now minus 24h" cannot be compared against itself tomorrow, and two
  unpinned windows are how a volume collapse gets read as a repair.

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

    try do
      %{
        windows: Enum.map(@deploy_windows, &window_health(&1, now)),
        measured_at: now,
        unmeasured: false,
        reason: nil
      }
    rescue
      e -> unmeasured_deploy(now, "the deploy ledger could not be read: #{Exception.message(e)}")
    catch
      :exit, reason ->
        unmeasured_deploy(now, "the deploy ledger read exited: #{inspect(reason)}")
    end
  end

  defp window_health({label, seconds}, now) do
    from = DateTime.add(now, -seconds, :second)

    # `site_limit: 0` because this block reports the fleet's RATE, never a
    # per-site league table: the digest is delivered per team, and a named list
    # of the busiest sites would be the cross-team disclosure the per-team
    # partition exists to prevent. Counts and percentages name nobody.
    census = DeployLedger.census(from, now, site_limit: 0)

    %{
      label: label,
      from: from,
      to: now,
      door: census.volume,
      deferred: Enum.reduce(census.deferred, 0, &(&1.count + &2)),
      failed: census.failed,
      rate: census.failure_rate
    }
  end

  defp unmeasured_deploy(measured_at, reason),
    do: %{windows: [], measured_at: measured_at, unmeasured: true, reason: reason}

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

  # THE DEPLOY-HEALTH BLOCK (dr-w27-s8). Four shapes, and three of them are the
  # word UNMEASURED — because every way this reading can be absent is a way the
  # old payload was silently reassuring. A missing `:deploy` key is the fourth
  # and is treated the same as an explicit refusal: a summary map built without
  # one has not measured anything, whoever built it.
  defp deploy_block(%{deploy: %{unmeasured: true, reason: reason}}),
    do: "Deploy health: UNMEASURED — #{reason}."

  defp deploy_block(%{deploy: %{windows: []}}),
    do: "Deploy health: UNMEASURED — the ledger returned no windows to report."

  defp deploy_block(%{deploy: %{windows: windows} = d}) do
    "Deploy health (control-plane deploy ledger, read #{format_ts(d.measured_at)}):\n" <>
      Enum.map_join(windows, "\n", &deploy_line/1)
  end

  defp deploy_block(_s),
    do: "Deploy health: UNMEASURED — this send supplied no deploy-ledger reading."

  # ONE DOOR. The attempted population and the deferral mass inside it are
  # printed BEFORE the percentage and on the same line, so the rate cannot be
  # quoted without them: a busy box refusing a slot is the fleet working as
  # designed, and it was 66% of one of these doors and 6% of the other.
  defp deploy_line(%{door: 0} = w) do
    "  #{w.label} (#{span(w)}): UNMEASURED — no deploy rows at all in this window. " <>
      "A window with nothing in it is not a healthy fleet."
  end

  defp deploy_line(w) do
    "  #{w.label} (#{span(w)}): #{number(w.door)} attempted, of which " <>
      "#{number(w.deferred)} deferred by a busy box — #{rate_clause(w)}."
  end

  # The rate node's OWN refusal, carried through verbatim. The counts survive a
  # refusal (they are real rows); it is the ratio that is withheld, exactly as
  # `DeployLedger.census/3` withholds it one level up.
  defp rate_clause(%{rate: %{refused: true, reason: reason}} = w) do
    "failure rate UNMEASURED (#{reason}); #{number(w.failed)} of #{number(w.door)} " <>
      "attempted are settled failures"
  end

  defp rate_clause(%{rate: %{pct: pct}} = w) when is_number(pct) do
    "#{pct}% failed post-door (#{number(w.failed)} of #{number(w.door)} attempted)"
  end

  # A rate node that is neither refused nor a number is a producer this renderer
  # does not understand. It renders as UNMEASURED and never as a percentage —
  # the one direction this block is never allowed to fail in.
  defp rate_clause(w),
    do:
      "failure rate UNMEASURED (the ledger returned no usable rate); " <>
        "#{number(w.failed)} of #{number(w.door)} attempted are settled failures"

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
