defmodule BarkparkCloud.Notifications.DigestEmailTest do
  @moduledoc """
  dr-w25-s6 — the daily fleet digest email stops calling a stale box `current`.

  The defect this pins: `DigestEmail` counted `update_state == "current"`
  straight into the email SUBJECT, and `update_state` is the box's own
  RELEASE-TAG self-grade. The fleet tag has not moved off `0.2.25` in ~2,500
  builds, so five prod boxes sitting 1 / 268 / 633 / 927 / 2,509 commits behind
  `main` were all reported `current` — drift within a release was invisible by
  construction.

  These tests read the rendered BYTES (subject line, header line, per-box row),
  not just the summary map, because the bytes are what a human receives. The
  MUTATION test at the bottom is the anti-vacuous-green guard: it flips one
  fixture's `commit_ancestry` and proves the counts move, so a future refactor
  that stops reading the measured column cannot keep these tests green.

  dr-w28-s5 adds section 8, the deploy-health block. `use BarkparkCloud.DataCase`
  (rather than the bare `ExUnit.Case` this file had) because the TENANCY test
  there MANUFACTURES TWO TEAMS with different sites and reads the real ledger:
  every other test in this file renders from hand-built fixture maps and would
  pass identically whether the reading is team-scoped or fleet-wide, so a
  fixture cannot decide the one question section 8 exists to answer. The pure
  tests are unaffected — they simply never touch the sandbox.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Notifications.DigestEmail
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Registry.Deployment

  @checked ~U[2026-08-07 14:02:00.000000Z]
  @measured ~U[2026-08-08 03:11:00.000000Z]

  # A box that grades ITSELF current on the unmoved release tag. Every fixture
  # starts here; each test supplies only the measured columns under test.
  defp box(attrs) do
    struct!(
      %Barkpark{
        name: "Prod",
        slug: "prod",
        version: "0.2.25",
        git_commit: "abc1234",
        update_state: "current",
        update_running_release: "v0.2.25",
        update_latest_release: "v0.2.25",
        update_checked_at: @checked,
        autoupdate_enabled: true,
        autoupdate_paused: false,
        pinned_release: nil
      },
      attrs
    )
  end

  defp stale_box(attrs \\ []) do
    box(
      [
        name: "Stale",
        slug: "stale",
        commit_ancestry: "behind",
        commit_distance: 2509,
        commit_distance_checked_at: @measured
      ] ++ attrs
    )
  end

  defp fresh_box(attrs \\ []) do
    box(
      [
        name: "Fresh",
        slug: "fresh",
        commit_ancestry: "current",
        commit_distance: 0,
        commit_distance_checked_at: @measured
      ] ++ attrs
    )
  end

  ## 1. The counts — a measured-behind box is never `current`

  test "a box 2,509 commits behind main lands in the behind bucket, not current" do
    summary = DigestEmail.summary([stale_box(), fresh_box()])

    assert summary.total == 2
    assert summary.behind == 1
    assert summary.current == 1
    assert summary.unmeasured == 0

    # ...and the box's own self-report is untouched: this is the plane
    # DISAGREEING with it, not the column being rewritten.
    assert DigestEmail.freshness(stale_box()) == :behind
    assert stale_box().update_state == "current"
  end

  test "a box whose commit matches main but whose release tag says behind is counted behind" do
    # The self-report can only ever make the verdict WORSE — never launder a
    # box into `current`.
    summary = DigestEmail.summary([fresh_box(update_state: "behind")])

    assert summary.behind == 1
    assert summary.current == 0
  end

  test "a tag-only behind box says WHICH producer called it behind, not '0 commits behind'" do
    # REVIEW ADDITION. `behind` is reachable two ways and only one of them is a
    # measurement. When the compare found NOTHING missing and the box's own
    # release tag is what said `behind`, the measured distance is genuinely 0 —
    # so the row used to read "state: behind | 0 commits behind main", which is
    # a flat contradiction with the reason dropped on the floor. The counting
    # test above already pinned the rung; this pins the BYTES a human reads.
    line = DigestEmail.body(DigestEmail.summary([fresh_box(update_state: "behind")]))

    assert line =~ "state: behind"
    assert line =~ "behind by its own release tag, not by commit"
    refute line =~ "| 0 commits behind main (measured 2026-08-08 03:11 UTC) |"
  end

  test "the five measured rungs partition the fleet" do
    rows = [
      stale_box(),
      fresh_box(),
      box(name: "D", slug: "d", commit_ancestry: "diverged", commit_distance: 4),
      box(name: "A", slug: "a", commit_ancestry: "ahead_of_main", commit_distance: 2),
      box(name: "U", slug: "u", commit_ancestry: nil)
    ]

    s = DigestEmail.summary(rows)

    assert s.current + s.behind + s.diverged + s.ahead + s.unmeasured == s.total
    assert {s.current, s.behind, s.diverged, s.ahead, s.unmeasured} == {1, 1, 1, 1, 1}
  end

  ## 2. The SUBJECT LINE carries the corrected counts

  test "the subject line reports the stale box as behind, not current" do
    subject = DigestEmail.subject(DigestEmail.summary([stale_box(), fresh_box()]))

    assert subject == "Barkpark fleet digest — 1 current / 1 behind / 0 unmeasured / 0 paused"

    # BEFORE this slice the same fixture rendered "2 current / 0 behind /
    # 0 paused" — both boxes self-report `current` on the unmoved tag. That is
    # the exact byte-level lie this asserts is gone.
    refute subject =~ "2 current"
  end

  test "a fleet of five prod boxes behind main never reports a single one current" do
    rows =
      for d <- [1, 268, 633, 927, 2509] do
        box(
          name: "box-#{d}",
          slug: "box-#{d}",
          commit_ancestry: "behind",
          commit_distance: d,
          commit_distance_checked_at: @measured
        )
      end

    subject = DigestEmail.subject(DigestEmail.summary(rows))

    assert subject == "Barkpark fleet digest — 0 current / 5 behind / 0 unmeasured / 0 paused"
  end

  ## 3. UNMEASURED is its own rung, with a named reason

  test "a NULL commit_ancestry is unmeasured with a named reason — never current, never behind" do
    row = box(name: "Never", slug: "never", commit_ancestry: nil)
    s = DigestEmail.summary([row])

    assert {s.current, s.behind, s.unmeasured} == {0, 0, 1}
    assert DigestEmail.subject(s) =~ "0 current / 0 behind / 1 unmeasured"

    body = DigestEmail.body(s)
    assert body =~ "Fleet: 1 instance — 0 current, 0 behind, 1 unmeasured, 0 paused."

    assert body =~
             "- Never (never): v0.2.25 -> v0.2.25 | state: unmeasured (release self-report: current) | commit distance unmeasured (never measured) | checked 2026-08-07 14:02 UTC"
  end

  test "\"unknown\" names WHICH failure mode left it unmeasured" do
    offline =
      box(
        name: "Offline",
        slug: "offline",
        git_commit: nil,
        commit_ancestry: "unknown",
        commit_distance: nil,
        commit_distance_checked_at: @measured
      )

    refused =
      box(
        name: "Refused",
        slug: "refused",
        commit_ancestry: "unknown",
        commit_distance: nil,
        commit_distance_checked_at: @measured
      )

    body = DigestEmail.body(DigestEmail.summary([offline, refused]))

    assert body =~
             "commit distance unmeasured (instance has reported no commit; last asked 2026-08-08 03:11 UTC)"

    assert body =~
             "commit distance unmeasured (no usable answer from the commit compare; last asked 2026-08-08 03:11 UTC)"

    # The unmeasured pair is NOT quietly rounded into either bucket.
    s = DigestEmail.summary([offline, refused])
    assert {s.current, s.behind, s.unmeasured} == {0, 0, 2}
  end

  ## 4. `diverged` gets its own word

  test "diverged is its own word in the counts, the subject and the row" do
    row =
      box(
        name: "Fork",
        slug: "fork",
        commit_ancestry: "diverged",
        commit_distance: 7,
        commit_distance_checked_at: @measured
      )

    s = DigestEmail.summary([row])
    assert {s.current, s.behind, s.diverged} == {0, 0, 1}

    assert DigestEmail.subject(s) ==
             "Barkpark fleet digest — 0 current / 0 behind / 1 diverged / 0 unmeasured / 0 paused"

    assert DigestEmail.body(s) =~
             "- Fork (fork): v0.2.25 -> v0.2.25 | state: diverged (release self-report: current) | diverged from main, 7 commits not on main (measured 2026-08-08 03:11 UTC) | checked 2026-08-07 14:02 UTC"
  end

  test "ahead of main is its own word too, and appears only when a box is on it" do
    ahead =
      box(
        name: "Ahead",
        slug: "ahead",
        commit_ancestry: "ahead_of_main",
        commit_distance: 3,
        commit_distance_checked_at: @measured
      )

    assert DigestEmail.subject(DigestEmail.summary([ahead])) =~ "1 ahead of main"
    refute DigestEmail.subject(DigestEmail.summary([fresh_box()])) =~ "ahead of main"
    assert DigestEmail.body(DigestEmail.summary([ahead])) =~ "3 commits ahead of main"
  end

  ## 5. The distance is measured AT A TIME, never a constant

  test "the per-box row carries the distance together with its checked_at" do
    body = DigestEmail.body(DigestEmail.summary([stale_box()]))

    assert body =~
             "- Stale (stale): v0.2.25 -> v0.2.25 | state: behind (release self-report: current) | 2509 commits behind main (measured 2026-08-08 03:11 UTC) | checked 2026-08-07 14:02 UTC"

    # The SAME box measured again renders a different distance AND a different
    # measured-at — proof the number is presented as a reading, not a constant.
    later =
      stale_box(
        commit_distance: 2609,
        commit_distance_checked_at: ~U[2026-08-09 03:11:00.000000Z]
      )

    assert DigestEmail.body(DigestEmail.summary([later])) =~
             "2609 commits behind main (measured 2026-08-09 03:11 UTC)"
  end

  test "a measured verdict with no recorded clock says so rather than implying now" do
    row = stale_box(commit_distance_checked_at: nil)

    assert DigestEmail.body(DigestEmail.summary([row])) =~
             "2509 commits behind main (measured at an unrecorded time)"
  end

  test "a measured-behind box with no recorded distance never renders as 0" do
    row = stale_box(commit_distance: nil)
    body = DigestEmail.body(DigestEmail.summary([row]))

    assert body =~ "an unrecorded number of commits behind main"
    refute body =~ "0 commits behind main"
  end

  ## 6. MUTATION — the counts actually READ the measured column

  test "MUTATION: flipping commit_ancestry behind -> current moves the box between buckets" do
    behind = DigestEmail.summary([stale_box()])
    assert behind.behind == 1
    assert behind.current == 0

    # The ONLY field that changes is the one the plane measures.
    flipped = DigestEmail.summary([stale_box(commit_ancestry: "current")])
    assert flipped.behind == 0
    assert flipped.current == 1

    # If the counting ever stops reading `commit_ancestry`, these two subjects
    # become identical and this assertion reds.
    refute DigestEmail.subject(behind) == DigestEmail.subject(flipped)
  end

  ## 7. The email struct still renders, and the empty fleet is still honest

  test "build/2 renders the corrected subject into the actual email struct" do
    email = DigestEmail.build(DigestEmail.summary([stale_box(), fresh_box()]), "ops@example.com")

    assert email.subject ==
             "Barkpark fleet digest — 1 current / 1 behind / 0 unmeasured / 0 paused"

    assert email.text_body =~ "2509 commits behind main"
    assert [{_, "ops@example.com"}] = email.to
  end

  test "an empty fleet still renders a clear no-instances digest" do
    s = DigestEmail.summary([])

    assert DigestEmail.subject(s) ==
             "Barkpark fleet digest — 0 current / 0 behind / 0 unmeasured / 0 paused"

    body = DigestEmail.body(s)
    assert body =~ "Fleet: 0 instances."
    assert body =~ "No instances are registered yet"
  end

  test "policy flags still render beside the measured verdict" do
    row = stale_box(autoupdate_paused: true, pinned_release: "v0.2.20", autoupdate_enabled: false)

    body = DigestEmail.body(DigestEmail.summary([row]))

    assert body =~ "| pinned=v0.2.20, paused, autoupdate off | checked"
    assert body =~ "2509 commits behind main"
  end

  ## 8. dr-w28-s5 — THE DIGEST NAMES DEPLOY HEALTH, FOR THE TEAM'S OWN SITES
  ##
  ## The digest reached a human for the first time ever at 2026-08-09T06:00:00Z
  ## (four notification_deliveries rows, event=fleet_digest, status=sent) and
  ## the payload was deploy-blind: it told four people nothing about their
  ## deploy failures. These tests read the BYTES of the block that fixes that,
  ## and they exist mostly to pin what it is NOT allowed to say.
  ##
  ## `summary/2` takes the reading as an argument, so the render shapes below
  ## are exercised without a database. THE TENANCY TEST IS THE EXCEPTION AND
  ## THAT IS THE POINT: it manufactures two teams with different sites and real
  ## ledger rows, because a fixture-fed reading is green by construction whether
  ## the scope is the team or the whole platform.

  @read_at ~U[2026-08-09 06:00:00Z]

  # The instant both tenancy tests pin their windows at, so the rows they insert
  # and the census they compare against share one clock.
  @ledger_now ~U[2026-08-09 12:00:00Z]

  # THE DOUBLE CARRIES BOTH BASES (dr-w31/D525), because the renderer under test
  # now prints both and a double that carried one would make every assertion
  # below a test of the ABSENT-node arm rather than of the rendered pair.
  #
  # `settled` defaults to `door - deferred` HERE, IN A TEST DOUBLE ONLY — the
  # production reader takes it from `census.failed + census.live` and never from
  # a subtraction (D257 forbids the subtractive success count, which folds
  # in-flight, cancelled and residual rows into `live`). A caller that needs a
  # settled cohort the subtraction cannot express passes it explicitly.
  defp window(label, door, deferred, failed, rate, settled \\ nil) do
    settled = settled || door - deferred

    %{
      label: label,
      from: DateTime.add(@read_at, -86_400, :second),
      to: @read_at,
      door: door,
      deferred: deferred,
      failed: failed,
      settled: settled,
      rate: rate,
      terminal_rate: terminal_rate(failed, settled, rate)
    }
  end

  # The settled-basis twin, refusing on ITS OWN sample. It refuses exactly when
  # the attempted node refuses is NOT the rule: the two denominators differ, so
  # each crosses `min_sample` on its own — that is the point of printing both.
  defp terminal_rate(failed, settled, _rate) when settled >= 200 do
    %{
      sample: settled,
      pct: Float.round(failed * 100 / settled, 2),
      numerator: failed,
      min_sample: 200,
      refused: false,
      reason: nil,
      basis: "TERMINAL rows only: failed + live"
    }
  end

  defp terminal_rate(failed, settled, _rate) do
    %{
      sample: settled,
      pct: nil,
      numerator: failed,
      min_sample: 200,
      refused: true,
      reason: "sample #{settled} below min_sample 200",
      basis: "TERMINAL rows only: failed + live"
    }
  end

  defp measured_rate(numerator, denominator) do
    %{
      sample: denominator,
      pct: Float.round(numerator * 100 / denominator, 2),
      numerator: numerator,
      min_sample: 200,
      refused: false,
      reason: nil,
      basis: "attempted rows in the window"
    }
  end

  defp refused_rate(denominator, reason) do
    %{
      sample: denominator,
      pct: nil,
      numerator: 0,
      min_sample: 200,
      refused: true,
      reason: reason,
      basis: "attempted rows in the window"
    }
  end

  # The wait node as `DeployLedger.census/3` actually returns it — a `max`
  # quantile beside the population it was measured over.
  defp measured_wait(seconds, covered, deferred, pending) do
    %{
      population: %{
        deferred: deferred,
        covered: covered,
        pending: pending,
        unreadable: deferred - covered - pending
      },
      sample: covered,
      unresolved: pending,
      max: %{
        label: "max",
        quantile: 1.0,
        seconds: seconds,
        sample: covered,
        min_sample: 200,
        refused: false,
        reason: nil
      }
    }
  end

  defp refused_wait(covered, deferred, pending, reason) do
    %{
      population: %{
        deferred: deferred,
        covered: covered,
        pending: pending,
        unreadable: deferred - covered - pending
      },
      sample: covered,
      unresolved: pending,
      max: %{
        label: "max",
        quantile: 1.0,
        seconds: nil,
        sample: covered,
        min_sample: 200,
        refused: true,
        reason: reason
      }
    }
  end

  defp with_wait(window, wait), do: Map.put(window, :wait, wait)

  defp health(windows) do
    %{
      windows: windows,
      measured_at: @read_at,
      unmeasured: false,
      no_sites: false,
      reason: nil
    }
  end

  test "the digest body names the deploy doors — and every rate carries its deferred population" do
    deploy =
      health([
        window("last 24h", 852, 564, 53, measured_rate(53, 852)),
        %{
          window("last 7d", 9_156, 3_043, 6_180, measured_rate(6_180, 9_156), 6_180)
          | from: DateTime.add(@read_at, -604_800, :second)
        }
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "Deploy health for this team's sites (control-plane deploy ledger, read 2026-08-09 06:00 UTC):"

    # THE BINDING SHAPE: door, deferrals and BOTH bases of the rate on ONE line.
    assert body =~
             "  last 24h (2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC): 852 attempted, of which 564 deferred by a busy box — 6.22% failed on attempted (53 of 852 attempted); 18.4% failed on settled (53 of 288 settled)."

    assert body =~
             "  last 7d (2026-08-02 06:00 UTC to 2026-08-09 06:00 UTC): 9,156 attempted, of which 3,043 deferred by a busy box — 67.5% failed on attempted (6,180 of 9,156 attempted); 100.0% failed on settled (6,180 of 6,180 settled)."
  end

  test "a rate can never be rendered without its door and its deferrals beside it" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    [line] = for l <- String.split(body, "\n"), l =~ "failed on attempted", do: l

    # Every number the percentage depends on is on the SAME line as the
    # percentage. A future refactor that splits them apart reds here.
    assert line =~ "852 attempted"
    assert line =~ "564 deferred"
    assert line =~ "6.22%"
  end

  test "a window with no rows renders UNMEASURED — never 0%, never healthy" do
    deploy =
      health([window("last 24h", 0, 0, 0, refused_rate(0, "sample 0 below min_sample 200"))])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "  last 24h (2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC): UNMEASURED — no deploy rows at all in this window for this team's sites. A window with nothing in it is not a clean bill of health."

    # The reassuring readings a zero window must never be able to produce.
    refute body =~ "0% failed"
    refute body =~ "0.0% failed"
    refute body =~ "failed on attempted"
  end

  test "an empty window and a team with NO SITES are different sentences" do
    empty_window =
      DigestEmail.body(
        DigestEmail.summary([fresh_box()],
          deploy:
            health([
              window("last 24h", 0, 0, 0, refused_rate(0, "sample 0 below min_sample 200"))
            ])
        )
      )

    no_sites = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: no_sites_reading()))

    # THE FALSE ALARM THIS ARM EXISTS TO STOP. A team that owns no sites is not
    # a team whose deploys stopped, and it must not be told every morning that a
    # window had nothing in it.
    assert no_sites =~
             "Deploy health: this team owns no sites, so it ran no deploys — nothing was measured here and nothing is being withheld."

    refute no_sites =~ "no deploy rows at all in this window"
    refute no_sites =~ "not a clean bill of health"
    refute no_sites =~ "UNMEASURED"
    assert empty_window =~ "no deploy rows at all in this window"
    refute empty_window == no_sites
  end

  test "a refused rate keeps its counts and withholds only the ratio" do
    deploy =
      health([window("last 24h", 74, 12, 3, refused_rate(74, "sample 74 below min_sample 200"))])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "  last 24h (2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC): 74 attempted, of which 12 deferred by a busy box — failure rate on attempted UNMEASURED (sample 74 below min_sample 200); 3 of 74 attempted are settled failures; failure rate on settled UNMEASURED (sample 62 below min_sample 200); 3 of 62 settled are settled failures"

    refute body =~ "% failed on attempted"
  end

  ## ── THE DEFERRAL WAIT ─────────────────────────────────────────────────────
  ##
  ## The count answers "how often did a box say not now". Only the wait answers
  ## "and how long did that cost the site" — and the live release rendered the
  ## count alone while `census.deferral_wait` sat unread in the same reading.

  test "the deferral wait rides on the same line as the deferrals it is a wait for" do
    deploy =
      health([
        with_wait(
          window("last 24h", 760, 502, 18, measured_rate(18, 760)),
          measured_wait(2_500.0, 492, 502, 8)
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "760 attempted, of which 502 deferred by a busy box — 2.37% failed on attempted (18 of 760 attempted); 6.98% failed on settled (18 of 258 settled). " <>
               "The slowest of those deferrals waited 41.7m for a box; 492 of 502 deferred rows have since rebuilt, 8 are still waiting."

    # The wait and the population it was measured over are on ONE line, for the
    # same reason the rate and its door are: a fast max over a sliver of the
    # population is not a fast platform.
    [line] = for l <- String.split(body, "\n"), l =~ "slowest of those deferrals", do: l
    assert line =~ "502 deferred by a busy box"
    assert line =~ "492 of 502"
  end

  test "a wait the census REFUSED prints its refusal and its population — never a number" do
    deploy =
      health([
        with_wait(
          window("last 24h", 74, 12, 3, refused_rate(74, "sample 74 below min_sample 200")),
          refused_wait(9, 12, 3, "sample 9 below min_sample 200")
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "Deferral wait UNMEASURED (sample 9 below min_sample 200); 9 of 12 deferred rows have since rebuilt, 3 are still waiting."

    # A refusal that rendered as a duration, or as nothing at all, is the two
    # failures this clause exists to make impossible.
    refute body =~ "slowest of those deferrals"
    refute body =~ "busy box — 2"
  end

  test "the zero-headroom refusal reaches the reader in the census's own words" do
    reason =
      "max is UNIDENTIFIABLE: 0.41% of the deferred population is unresolved " <>
        "(still waiting, or unreadable), exceeding the 0.0% headroom max needs"

    deploy =
      health([
        with_wait(
          window("last 24h", 760, 241, 18, measured_rate(18, 760)),
          refused_wait(240, 241, 1, reason)
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "Deferral wait UNMEASURED (#{reason}); 240 of 241 deferred rows have since rebuilt, 1 are still waiting."

    refute body =~ "slowest of those deferrals"
  end

  test "a reading that carries no wait node renders UNMEASURED — never a fast one" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~ "Deferral wait UNMEASURED (the ledger returned no usable wait)."
    refute body =~ "slowest of those deferrals"
  end

  test "a window with no rows at all carries no wait clause — there is nothing to have waited" do
    deploy =
      health([
        with_wait(
          window("last 24h", 0, 0, 0, refused_rate(0, "sample 0 below min_sample 200")),
          refused_wait(0, 0, 0, "sample 0 below min_sample 200")
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~ "UNMEASURED — no deploy rows at all in this window"
    refute body =~ "Deferral wait"
    refute body =~ "deferred rows have since rebuilt"
  end

  ## ── THE COVERAGE PARTITION (dr-w32-s3) ────────────────────────────────────
  ##
  ## The wait above is a clock over DEFERRED rows only. This is the same clock's
  ## verdict over the deferred AND the failed-terminating cohorts, and it rides
  ## the digest for one reason: it is the gauge the epic's wind-down rests on,
  ## and a gauge nobody is shown every morning is not a gauge.

  defp cohort(cohort, population, covered, never_covered, opts \\ []) do
    %{
      cohort: cohort,
      status: cohort,
      population: population,
      covered: covered,
      pending: never_covered + Keyword.get(opts, :too_young, 0),
      unreadable: Keyword.get(opts, :unreadable, 0),
      matured: covered + never_covered,
      never_covered: never_covered,
      too_young: Keyword.get(opts, :too_young, 0),
      never_covered_by_environment: Keyword.get(opts, :by_environment, []),
      oldest_pending_seconds: Keyword.get(opts, :oldest_pending_seconds)
    }
  end

  defp with_coverage(window, cohorts) do
    Map.put(window, :coverage, %{
      clock: "the SAME clock as `deferral_wait`",
      basis: "COVERAGE, and only coverage",
      as_of: @read_at,
      maturity_seconds: 86_400,
      cohorts: cohorts
    })
  end

  test "the coverage partition reaches the reader, with its window and its fence named" do
    deploy =
      health([
        with_coverage(
          window("last 24h", 760, 502, 18, measured_rate(18, 760)),
          [
            cohort("deferred", 502, 502, 0),
            cohort("failed", 18, 15, 2,
              too_young: 1,
              by_environment: [%{environment: "production", never_covered: 2}]
            )
          ]
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    # THE SPLIT THE LEDGER ALWAYS COMPUTED IS NOW REQUIRED (dr-w33-s3). This
    # fixture has always passed `by_environment` and this assertion used to watch
    # it be dropped and pass green; naming the environment is the difference
    # between "2 never covered" and "2 production sites never covered".
    assert body =~
             "Coverage over last 24h (COVERED means the site has since rebuilt, not that an edit of yours shipped): " <>
               "502 of 502 deferred rows have since been covered by a later live build, 0 still not after 24.0h; " <>
               "15 of 18 failed rows have since been covered by a later live build, 2 still not after 24.0h (1 too young to judge) — of those, 2 in production."

    # THE FAILED TAIL IS ON THE SAME LINE AS THE DEFERRED ONE and is never
    # pooled with it: the two cohorts are separate populations, and one number
    # covering both is the reassurance this clause exists to refuse.
    [line] = for l <- String.split(body, "\n"), l =~ "Coverage over last 24h", do: l
    assert line =~ "deferred rows"
    assert line =~ "failed rows"

    # D478's wording fence, on the bytes a human actually receives.
    refute body =~ "delivered"
    refute body =~ "superseded"
    refute body =~ "publish reach"
  end

  test "a cohort with nothing never-covered prints no environment breakdown" do
    # NON-VACUITY, THE OTHER DIRECTION: the split is a breakdown OF the
    # never-covered count, so a zero must not sprout an environment clause — a
    # morning email that names production next to a clean cohort is a false alarm.
    deploy =
      health([
        with_coverage(
          window("last 24h", 760, 502, 18, measured_rate(18, 760)),
          [
            cohort("failed", 18, 18, 0,
              by_environment: [%{environment: "production", never_covered: 0}]
            )
          ]
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~ "18 of 18 failed rows have since been covered by a later live build, 0 still"
    refute body =~ "of those,"
    refute body =~ "in production"
  end

  test "a cohort whose by_environment key is ABSENT still renders, and never raises" do
    # The digest reads the split with `Map.get/3` for the same reason its head
    # names every count it prints: a ledger shape it cannot read must cost one
    # fragment, never the whole email.
    deploy =
      health([
        with_coverage(
          window("last 24h", 760, 502, 18, measured_rate(18, 760)),
          [
            cohort("failed", 18, 15, 3)
            |> Map.delete(:never_covered_by_environment)
          ]
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "15 of 18 failed rows have since been covered by a later live build, 3 still not after 24.0h."

    refute body =~ "of those,"
    refute body =~ "a cohort the digest could not read"
  end

  test "the reach limit is named, and it is the widest window the email reports" do
    deploy =
      health([
        with_coverage(
          window("last 24h", 760, 502, 18, measured_rate(18, 760)),
          [cohort("failed", 18, 18, 0)]
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~
             "Reach limit: last 7d is the widest window this email reports, so a row older than that is OUTSIDE this population rather than covered by it."
  end

  test "the reach limit is stated ONCE per email, not once per window" do
    # The real send carries EVERY door in `@deploy_windows`, so a per-window
    # sentence would repeat verbatim under each one. Two windows here, and the
    # widest door names itself exactly once.
    deploy =
      health([
        with_coverage(
          window("last 24h", 760, 502, 18, measured_rate(18, 760)),
          [cohort("failed", 18, 16, 2)]
        ),
        with_coverage(
          window("last 7d", 9_156, 6_040, 91, measured_rate(91, 9_156)),
          [cohort("failed", 91, 89, 2)]
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert length(String.split(body, "Reach limit:")) - 1 == 1
  end

  test "the reach limit survives every window falling to coverage-UNMEASURED" do
    # A disclosure that disappears exactly when the numbers get less trustworthy
    # is fail-open. Neither window carries a coverage node here.
    deploy =
      health([
        window("last 24h", 760, 502, 18, measured_rate(18, 760)),
        window("last 7d", 9_156, 6_040, 91, measured_rate(91, 9_156))
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~ "Coverage UNMEASURED (the ledger returned no coverage cohorts)"
    assert body =~ "Reach limit: last 7d is the widest window this email reports"
  end

  test "a reading that carries no coverage node renders UNMEASURED — never full coverage" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~ "Coverage UNMEASURED (the ledger returned no coverage cohorts)."
    refute body =~ "have since been covered"
  end

  test "an empty cohort says it has no rows — zero of zero is not full coverage" do
    deploy =
      health([
        with_coverage(
          window("last 24h", 760, 502, 0, measured_rate(0, 760)),
          [cohort("deferred", 502, 502, 0), cohort("failed", 0, 0, 0)]
        )
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    assert body =~ "no failed rows"
    refute body =~ "0 of 0 failed rows"
  end

  test "a send that supplied no reading says so — the omission cannot render as a clean team" do
    body = DigestEmail.body(DigestEmail.summary([fresh_box()]))

    assert body =~ "Deploy health: UNMEASURED — this send supplied no deploy-ledger reading."
    refute body =~ "failed on attempted"
  end

  test "no team scope is UNMEASURED and is NEVER read as the whole fleet" do
    # `nil` is `census/3`'s word for UNSCOPED, and a fleet-wide reading inside a
    # per-team email is the disclosure the scoping exists to close. Both the
    # absent option and an explicit `nil` fail CLOSED.
    for reading <- [
          DigestEmail.deploy_health(now: @read_at),
          DigestEmail.deploy_health(now: @read_at, site_ids: nil)
        ] do
      assert %{unmeasured: true, no_sites: false, windows: []} = reading

      body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: reading))

      assert body =~
               "Deploy health: UNMEASURED — this send supplied no team scope, so no reading was taken."

      refute body =~ "failed on attempted"
      refute body =~ "attempted, of which"
    end
  end

  test "a site lookup that failed renders UNMEASURED with the failure's own words" do
    reading =
      DigestEmail.deploy_health(now: @read_at, site_ids: {:error, "connection not available"})

    assert %{unmeasured: true, windows: []} = reading

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: reading))

    assert body =~
             "Deploy health: UNMEASURED — this team's sites could not be listed: connection not available."
  end

  test "an unreadable ledger renders UNMEASURED and the digest still goes out" do
    # A junk site id is a real production failure mode, not a hypothetical:
    # `site_ids` is interpolated into a `binary_id` column, so a non-UUID raises
    # `Ecto.Query.CastError` — a 500 if it escaped. It must not escape.
    reading = DigestEmail.deploy_health(now: @read_at, site_ids: ["not-a-uuid"])

    assert %{unmeasured: true, windows: [], reason: reason} = reading
    assert reason =~ "the deploy ledger could not be read"

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: reading))
    assert body =~ "Deploy health: UNMEASURED — the deploy ledger could not be read"
    refute body =~ "failed on attempted"
  end

  test "the digest never prints a lifetime deploy rate" do
    deploy =
      health([
        window("last 24h", 852, 564, 53, measured_rate(53, 852)),
        window("last 7d", 9_156, 3_043, 6_180, measured_rate(6_180, 9_156), 6_180)
      ])

    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: deploy))

    # The all-time numerator's honest freeze point is 2026-08-08T14:55:28.776961
    # at 18,640 — a number that is stale the moment it is written down. Only
    # windows this send pinned itself may be reported.
    refute body =~ "lifetime"
    refute body =~ "all-time"
    refute body =~ "18,640"
    refute body =~ "18640"

    # ...and every window it DOES report names both of its own bounds.
    assert body =~ "2026-08-08 06:00 UTC to 2026-08-09 06:00 UTC"
  end

  test "the deploy block reaches the actual email struct, not just body/1" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])

    email =
      DigestEmail.build(
        DigestEmail.summary([stale_box()], deploy: deploy),
        "ops@example.com"
      )

    assert email.text_body =~ "852 attempted, of which 564 deferred by a busy box"
  end

  test "an empty instance list still reports deploy health — sites deploy with no instance registered" do
    deploy = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    body = DigestEmail.body(DigestEmail.summary([], deploy: deploy))

    assert body =~ "No instances are registered yet"
    assert body =~ "852 attempted, of which 564 deferred"
  end

  test "MUTATION: the rendered percentage is DERIVED from the reading, not baked" do
    six = health([window("last 24h", 852, 564, 53, measured_rate(53, 852))])
    sixty = health([window("last 24h", 852, 564, 575, measured_rate(575, 852))])

    six_body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: six))
    sixty_body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: sixty))

    assert six_body =~ "6.22% failed on attempted (53 of 852 attempted)"
    assert sixty_body =~ "67.49% failed on attempted (575 of 852 attempted)"

    # If the block ever stops reading the reading, these two bodies become
    # identical and this reds.
    refute six_body == sixty_body
  end

  ## ── THE TENANCY PROOF ─────────────────────────────────────────────────────
  ##
  ## TWO REAL TEAMS, TWO REAL SITES, REAL LEDGER ROWS. Everything above renders
  ## from a fixture map and passes identically whether `deliver_fleet_digest/1`
  ## takes one fleet-wide reading or one per team — which is exactly why a
  ## fixture cannot settle this. These read the database through
  ## `Registry.list_sites_for_team/1`, the same list the digest narrows by.

  test "each team's digest carries ITS OWN deploy numbers, and never the platform's" do
    {_ua, team_a} = user_team()
    {_ub, team_b} = user_team()

    site_a = site_fixture(team_a)
    site_b = site_fixture(team_b)

    # 7 attempted rows for A (5 settled failures), 2 for B (1 failure). Both
    # doors sit below `min_sample` 200, so both rates are REFUSED and the counts
    # survive — the honest shape a small team actually receives.
    deployments!(site_a, 5, "failed")
    deployments!(site_a, 2, "live")
    deployments!(site_b, 1, "failed")
    deployments!(site_b, 1, "live")

    body_a = team_body(team_a)
    body_b = team_body(team_b)

    assert body_a =~ "7 attempted, of which 0 deferred by a busy box"
    assert body_a =~ "5 of 7 attempted are settled failures"

    assert body_b =~ "2 attempted, of which 0 deferred by a busy box"
    assert body_b =~ "1 of 2 attempted are settled failures"

    # NEITHER TEAM IS SHOWN THE OTHER'S ROWS...
    refute body_a =~ "2 attempted, of which"
    refute body_b =~ "7 attempted, of which"

    # ...NOR THE PLATFORM TOTAL THAT CONTAINS BOTH. This is the disclosure the
    # per-team scoping closes: the fleet-wide census over the same window is 9
    # attempted, and 9 is a number about the platform that neither of these two
    # teams may read off its own email.
    fleet = DeployLedger.census(DateTime.add(@ledger_now, -86_400, :second), @ledger_now)
    assert fleet.volume == 9
    refute body_a =~ "9 attempted"
    refute body_b =~ "9 attempted"

    # And the two bodies genuinely differ — a scoping that silently collapsed
    # would make these identical.
    refute body_a == body_b
  end

  test "a team that owns no sites is told so, and is not told the platform is unhealthy" do
    {_ua, team_a} = user_team()
    {_ub, empty_team} = user_team()

    # A busy platform around it: team A deploys, and every one of those deploys
    # fails. A fleet-wide reading would deliver that alarm to a team that owns
    # nothing, every morning.
    deployments!(site_fixture(team_a), 6, "failed")

    assert Registry.list_sites_for_team(empty_team) == []

    body = team_body(empty_team)

    assert body =~
             "Deploy health: this team owns no sites, so it ran no deploys — nothing was measured here and nothing is being withheld."

    refute body =~ "no deploy rows at all in this window"
    refute body =~ "not a clean bill of health"
    refute body =~ "attempted, of which"
    refute body =~ "6 attempted"

    # The busy neighbour IS visible to the team that owns it — the empty arm is
    # a scoping result, not a silenced reading.
    assert team_body(team_a) =~ "6 attempted, of which 0 deferred by a busy box"
  end

  test "the wait reaches the digest THROUGH the census, not through a fixture", %{} do
    {_u, team} = user_team()
    site = site_fixture(team)

    deployments!(site, 3, "deferred")
    deployments!(site, 2, "live")

    body = team_body(team)

    # Three real deferred rows, none of them covered by a later live build (the
    # live rows share their instant, and coverage is strictly later). The census
    # refuses the quantile at a sample of 0 and the counts survive — which is
    # exactly what a real small team receives.
    assert body =~ "5 attempted, of which 3 deferred by a busy box"

    assert body =~
             "Deferral wait UNMEASURED (sample 0 below min_sample 200); 0 of 3 deferred rows have since rebuilt, 3 are still waiting."

    # If `window_health/3` ever drops the key again, this reds — the fixture
    # tests above would not.
    refute body =~ "the ledger returned no usable wait"
  end

  test "a team that owns no sites is never told a deferral wait either" do
    body = DigestEmail.body(DigestEmail.summary([fresh_box()], deploy: no_sites_reading()))

    assert body =~
             "Deploy health: this team owns no sites, so it ran no deploys — nothing was measured here and nothing is being withheld."

    refute body =~ "Deferral wait"
    refute body =~ "deferred rows have since rebuilt"
    refute body =~ "slowest of those deferrals"
  end

  # Exactly what `Notifications.deliver_fleet_digest/1` does for one team: list
  # that team's sites, narrow the ledger read to them, render.
  defp team_body(team) do
    site_ids = team |> Registry.list_sites_for_team() |> Enum.map(& &1.id)

    DigestEmail.body(
      DigestEmail.summary([fresh_box()],
        deploy: DigestEmail.deploy_health(now: @ledger_now, site_ids: site_ids)
      )
    )
  end

  defp no_sites_reading, do: DigestEmail.deploy_health(now: @read_at, site_ids: [])

  defp user_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "digest-#{n}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp user_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Deployments are inserted as STRUCTS on purpose (the same reason
  # `DeployLedgerTest` does): `Deployment.changeset/2` forbids casting `status`,
  # and the census needs rows pinned to an exact `inserted_at` inside the window.
  defp deployments!(site, count, status) do
    at = %{DateTime.add(@ledger_now, -3600, :second) | microsecond: {0, 6}}

    for _ <- 1..count do
      Repo.insert!(%Deployment{
        site_id: site.id,
        status: status,
        environment: "production",
        failure_reason: if(status == "failed", do: "the build did not finish in time"),
        inserted_at: at,
        updated_at: at
      })
    end
  end
end
