defmodule BarkparkCloud.DeployLedgerJourneysTest do
  @moduledoc """
  A RELEASE JOURNEY IS A RUN, NOT A ROW — and not a `content_rev` group either
  (charter D142, scoped by D161; task `dr-bl-w9-journey-metric-run-based`).

  Ten waves of this epic counted ROWS. `DeployLedger.journeys/3` counts the
  ATTEMPTS one release cost, and this file pins the four properties that make
  that number honest rather than merely present.

  ## Every assertion below was proved to LOSE

  Each named mutation was applied to `deploy_ledger.ex` on this tree, the suite
  RUN, the failure observed, and the mutation reverted. The exact output is in
  the PR body. What each one proves:

    1. `Enum.group_by(&{&1.site_id, &1.run_no})` -> `&{&1.site_id, &1.content_rev}`
       — rev-group segmentation. Reds `a rev group is a content EPOCH…`: three
       live rows sharing one rev are THREE releases, and the rev group reads
       them as one.
    2. `defp journey_metered?(@unreadable_content_rev), do: false` -> `true`
       — folding the empty sentinel. Reds `the empty content_rev sentinel is
       UNMETERED…`: the strained-box degradation value is counted as a release.
    3. `journey_side_of/1`'s `cond` collapsed to `_ -> :pre` — dropping the
       boundary split. Reds `every figure is reported per side of the regime
       boundary`: post-door and straddling runs land in the pre-door figure.
    4. The run key back to `site_id` alone (`Enum.group_by` and the window
       `partition by`) — dropping the environment from the SEGMENTATION. Reds
       `a PREVIEW live row does not close a PRODUCTION run` and nothing else:
       the deferred-only population reads 0 where the truth is 1.
    5. `superseding_live/2` back to `group_by: d.site_id` with `superseded?/2`
       looking up by `site_id` — dropping the environment from the D212 probe.
       Reds `a later PREVIEW live row is NOT benign supersession`: a
       stranded production publish is credited as benignly superseded by a
       preview build that never touched `sites.current_deployment_id`.

  Mutations 4 and 5 both leave `a same-environment live row still closes the run
  AND still supersedes` GREEN — that arm is the control proving the environment
  key narrows the population rather than switching supersession off.

  ## What this file does NOT assert, on purpose

  No elapsed time. `delivery/3`'s @doc rejects run-keying as a WAIT clock and is
  right to — a `failed` row closes a run, so 80 of one site's 82 runs read 0.0 s
  across a 6 h 17 m outage. D161 scopes that refusal to the LATENCY and leaves
  "segment by RUN" governing attempt-cluster reporting, which is what this is.
  `journeys/3` emits no seconds key at all, so there is nothing here to misread.

  ## The corpus this renders over

  A FIXTURE, not production. No prod database read was available to this change,
  so the rendered lines in the PR body are the fixture's own figures and are
  labelled as such. The SHAPE of the line is the deliverable; the numbers on the
  fleet arrive when the closer PR routes the node.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, DeployLedger, Registry, Repo}
  alias BarkparkCloud.Registry.Deployment

  @password "correct-horse-battery"

  # PINNED, and straddling the D137 regime door on purpose: the split is the
  # thing under test, so a window on one side of it would make three of these
  # assertions vacuous.
  @from ~U[2026-08-06 00:00:00Z]
  @to ~U[2026-08-07 00:00:00Z]
  @door ~U[2026-08-06 22:24:16Z]

  # PINNED `as_of` for the deferred-only settling clause and the D212
  # supersession probe. A default `as_of` is `DateTime.utc_now/0`, which makes
  # the rendered line carry a moving instant and the whole-report equality
  # assertion below unrunnable — so every test that reads the D223 node pins it.
  @as_of ~U[2026-08-07 12:00:00Z]

  describe "segmentation" do
    test "a rev group is a content EPOCH, not a release — one rev going live three times is THREE journeys" do
      site = site_fixture()

      # ONE rev, THREE live rows. This is the corpus shape D142 measured (one rev
      # went live eleven times in 61 minutes) reduced to its smallest form.
      deployments!(site, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "aaaaaaaaaaaa"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "live", content_rev: "aaaaaaaaaaaa"},
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "deferred", content_rev: "aaaaaaaaaaaa"},
        %{inserted_at: ~U[2026-08-06 10:03:00Z], status: "deferred", content_rev: "aaaaaaaaaaaa"},
        %{inserted_at: ~U[2026-08-06 10:04:00Z], status: "live", content_rev: "aaaaaaaaaaaa"},
        %{inserted_at: ~U[2026-08-06 10:05:00Z], status: "live", content_rev: "aaaaaaaaaaaa"}
      ])

      live = pre(site).live

      # RUN: three runs of 2, 3 and 1 attempts = 3 journeys / 6 attempts / 2.00.
      # REV GROUP: one group of 6 attempts = 1 journey / 6.00, which is the
      # number mutation 1 publishes.
      assert live.journeys == 3
      assert live.attempts == 6
      assert live.attempts_per_journey == 2.0
    end

    test "a run is closed by the NEXT live/failed row, so failures and releases do not share a journey" do
      site = site_fixture()

      deployments!(site, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "bbbbbbbbbbbb"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "failed", content_rev: "bbbbbbbbbbbb"},
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "deferred", content_rev: "bbbbbbbbbbbb"},
        %{inserted_at: ~U[2026-08-06 10:03:00Z], status: "live", content_rev: "bbbbbbbbbbbb"}
      ])

      side = pre(site)

      assert side.live.journeys == 1
      assert side.live.attempts == 2
      assert side.failed.journeys == 1
      assert side.failed.attempts == 2
    end

    test "a trailing run with no terminal row is an OPEN RUN — counted, never metered" do
      site = site_fixture()

      deployments!(site, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "live", content_rev: "cccccccccccc"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "deferred", content_rev: "cccccccccccc"},
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "cancelled", content_rev: "cccccccccccc"}
      ])

      side = pre(site)

      assert side.live.journeys == 1
      assert side.live.attempts == 1
      assert side.open_runs == 1
    end
  end

  describe "the UNMETERED rev" do
    test "the empty content_rev sentinel is UNMETERED, never folded into the figure" do
      site = site_fixture()

      deployments!(site, [
        # A real release: two attempts, a readable rev.
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "dddddddddddd"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "live", content_rev: "dddddddddddd"},
        # The STRAINED-BOX degradation: `Sites.Deploy`'s @unknown_content_rev.
        # Six attempts, and folding it in would publish 4.00 over 2 journeys.
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "deferred", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:03:00Z], status: "deferred", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:04:00Z], status: "deferred", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:05:00Z], status: "deferred", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:06:00Z], status: "deferred", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:07:00Z], status: "live", content_rev: ""}
      ])

      live = pre(site).live

      assert live.journeys == 1
      assert live.attempts == 2
      assert live.attempts_per_journey == 2.0
      assert live.unmetered_journeys == 1
      assert live.unmetered_attempts == 6

      # AND THE EXCLUSION RIDES THE LINE. A figure whose excluded population is
      # one key away is a figure a renderer will one day print alone.
      assert journey_line(site, "live-terminated") =~
               "2.00 attempts over 1 journeys (2 attempts; 1 UNMETERED journeys excluded)"
    end

    test "a NULL content_rev is UNMETERED on the same rule" do
      site = site_fixture()

      deployments!(site, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "live", content_rev: "eeeeeeeeeeee"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "live", content_rev: nil}
      ])

      live = pre(site).live

      assert live.journeys == 1
      assert live.unmetered_journeys == 1
    end

    test "the metering reads the HEAD rev in ASC order, never min(content_rev)" do
      # THE ORDERING TRAP, in the direction a sha256 prefix cannot answer. Both
      # runs hold the same two revs; only their ORDER differs. `min/1` over a hex
      # prefix would answer "" for BOTH (the empty string sorts first), so the
      # two runs would meter identically — and they must not.
      unmetered_head = site_fixture()

      deployments!(unmetered_head, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "live", content_rev: "ffffffffffff"}
      ])

      metered_head = site_fixture()

      deployments!(metered_head, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "ffffffffffff"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "live", content_rev: ""}
      ])

      assert pre(unmetered_head).live.journeys == 0
      assert pre(unmetered_head).live.unmetered_journeys == 1
      assert pre(metered_head).live.journeys == 1
      assert pre(metered_head).live.unmetered_journeys == 0
    end
  end

  describe "the contended subset" do
    test "the fleet figure and the contended figure are DIFFERENT numbers, each with its own journey count" do
      site = site_fixture()

      deployments!(site, [
        # Uncontended release: one attempt.
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "live", content_rev: "111111111111"},
        # Uncontended release: one attempt.
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "live", content_rev: "111111111111"},
        # CONTENDED release: three deferrals then live = four attempts.
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "deferred", content_rev: "222222222222"},
        %{inserted_at: ~U[2026-08-06 10:03:00Z], status: "deferred", content_rev: "222222222222"},
        %{inserted_at: ~U[2026-08-06 10:04:00Z], status: "deferred", content_rev: "222222222222"},
        %{inserted_at: ~U[2026-08-06 10:05:00Z], status: "live", content_rev: "222222222222"}
      ])

      side = pre(site)

      assert side.live.journeys == 3
      assert side.live.attempts == 6
      assert side.live.attempts_per_journey == 2.0

      assert side.live_contended.journeys == 1
      assert side.live_contended.attempts == 4
      assert side.live_contended.attempts_per_journey == 4.0

      # THE CRITERION, READ OFF THE RENDERED LINE: both figures reported, each
      # carrying its own journey count on the SAME line.
      assert journey_line(site, "live-terminated") =~
               "2.00 attempts over 3 journeys (6 attempts; 0 UNMETERED journeys excluded)"

      assert journey_line(site, "contended subset") =~
               "4.00 attempts over 1 journeys (4 attempts; 0 UNMETERED journeys excluded)"
    end

    test "a cohort with no metered journey REFUSES rather than printing a zero" do
      site = site_fixture()

      deployments!(site, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "live", content_rev: "333333333333"}
      ])

      contended = pre(site).live_contended

      assert contended.refused
      assert is_nil(contended.attempts_per_journey)
      assert contended.reason =~ "no METERED journey"
      assert journey_line(site, "contended subset") =~ "REFUSED over 0 journeys"
    end
  end

  describe "the regime boundary" do
    test "every figure is reported per side of the regime boundary, and a straddling run is its own bucket" do
      # THREE sites, because a run is partitioned by `site_id`: putting all nine
      # rows on one site would chain them into runs that cross the door for
      # reasons the fixture, not the door, created.
      before_door = site_fixture()

      deployments!(before_door, [
        %{inserted_at: ~U[2026-08-06 20:00:00Z], status: "deferred", content_rev: "444444444444"},
        %{inserted_at: ~U[2026-08-06 20:01:00Z], status: "live", content_rev: "444444444444"}
      ])

      after_door = site_fixture()

      deployments!(after_door, [
        %{inserted_at: ~U[2026-08-06 23:00:00Z], status: "deferred", content_rev: "555555555555"},
        %{inserted_at: ~U[2026-08-06 23:01:00Z], status: "deferred", content_rev: "555555555555"},
        %{inserted_at: ~U[2026-08-06 23:02:00Z], status: "deferred", content_rev: "555555555555"},
        %{inserted_at: ~U[2026-08-06 23:03:00Z], status: "live", content_rev: "555555555555"}
      ])

      across = site_fixture()

      deployments!(across, [
        %{inserted_at: ~U[2026-08-06 22:00:00Z], status: "deferred", content_rev: "666666666666"},
        %{inserted_at: ~U[2026-08-06 23:30:00Z], status: "live", content_rev: "666666666666"}
      ])

      node =
        DeployLedger.journeys(@from, @to, site_ids: [before_door.id, after_door.id, across.id])

      assert node.boundary.instant == @door
      assert Enum.map(node.sides, & &1.side) == [:pre, :post, :straddling]

      pre_side = side(node, :pre)
      post_side = side(node, :post)
      straddle = side(node, :straddling)

      # The three figures are DISTINCT — 2.00, 4.00 and 2.00 over one journey
      # each. Mutation 3 collapses all three into a single 2.67 over 3 journeys.
      assert pre_side.live.journeys == 1
      assert pre_side.live.attempts_per_journey == 2.0

      assert post_side.live.journeys == 1
      assert post_side.live.attempts_per_journey == 4.0

      assert straddle.live.journeys == 1
      assert straddle.live.attempts_per_journey == 2.0

      # …and each side's line is rendered on its own, so no reader can average
      # across the door by accident.
      lines = DeployLedger.journey_report(node)

      assert Enum.any?(lines, &(&1 =~ "PRE-DOOR"))
      assert Enum.any?(lines, &(&1 =~ "POST-DOOR"))
      assert Enum.any?(lines, &(&1 =~ "STRADDLING"))

      assert line(lines, "PRE-DOOR", "live-terminated") =~ "2.00 attempts over 1 journeys"
      assert line(lines, "POST-DOOR", "live-terminated") =~ "4.00 attempts over 1 journeys"
      assert line(lines, "STRADDLING", "live-terminated") =~ "2.00 attempts over 1 journeys"
    end

    test "the node names the boundary, its provenance and what it voids" do
      node = DeployLedger.journeys(@from, @to, site_ids: [])

      assert node.boundary.source == "charter D137"
      assert node.boundary.method == "systemd_unit_transition"
      assert node.boundary.voids =~ "no rate crosses this instant"
      assert node.segmentation =~ "Never a `content_rev` group"
      assert node.basis =~ "never an elapsed time"
    end

    test "the node publishes NO elapsed time — run-keying is unfit for a wait clock (D161)" do
      node = DeployLedger.journeys(@from, @to, site_ids: [])

      refute node |> flatten_keys() |> Enum.any?(&clock_key?/1)
    end

    test "the clock-key predicate still catches a real duration key, and stops catching `settled`" do
      # THE CONTROL FOR THE TIGHTENING ABOVE. `ttl` used to be matched as a bare
      # substring, which reads `settled` / `unsettled` as duration keys — se-TTL-ed
      # — and would have refused charter D223's settling vocabulary for a reason
      # that has nothing to do with clocks. The arm is now a TOKEN match, and
      # this test is what proves the narrowing did not blind it: every duration
      # key shape D161 was defending against still trips it.
      assert Enum.all?(
               ~w(seconds wait_seconds elapsed elapsed_at ttl lease_ttl ttl_seconds),
               &clock_key?/1
             )

      refute Enum.any?(~w(settled unsettled settle_rule publishes superseded), &clock_key?/1)
    end
  end

  describe "the rendered report" do
    test "one mixed corpus, rendered whole — every cohort on every side carries its journey count" do
      # THE EVIDENCE LINE FOR THE CRITERIA, pinned as an EQUALITY rather than a
      # `=~`: a substring match on "2.00 attempts over 3 journeys" would still
      # pass if the excluded-UNMETERED clause fell off the end of the line, and
      # that clause is the whole of criterion 3. So the cohort lines are compared
      # WHOLE, in order, per side.
      #
      # The corpus is deliberately mixed: metered and unmetered heads, a
      # contended run, a failed-terminated run, an open run with no terminal row,
      # and one run that straddles the D137 door.
      pre_site = site_fixture()

      deployments!(pre_site, [
        %{inserted_at: ~U[2026-08-06 09:00:00Z], status: "live", content_rev: "a1a1a1a1a1a1"},
        %{inserted_at: ~U[2026-08-06 09:05:00Z], status: "live", content_rev: "a1a1a1a1a1a1"},
        %{inserted_at: ~U[2026-08-06 09:10:00Z], status: "deferred", content_rev: "a2a2a2a2a2a2"},
        %{inserted_at: ~U[2026-08-06 09:11:00Z], status: "deferred", content_rev: "a2a2a2a2a2a2"},
        %{inserted_at: ~U[2026-08-06 09:12:00Z], status: "deferred", content_rev: "a2a2a2a2a2a2"},
        %{inserted_at: ~U[2026-08-06 09:13:00Z], status: "live", content_rev: "a2a2a2a2a2a2"}
      ])

      unmetered_site = site_fixture()

      deployments!(unmetered_site, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "live", content_rev: ""},
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "deferred", content_rev: "b1b1b1b1b1b1"},
        %{inserted_at: ~U[2026-08-06 10:03:00Z], status: "failed", content_rev: "b1b1b1b1b1b1"}
      ])

      post_site = site_fixture()

      deployments!(post_site, [
        %{inserted_at: ~U[2026-08-06 23:00:00Z], status: "deferred", content_rev: "c1c1c1c1c1c1"},
        %{inserted_at: ~U[2026-08-06 23:01:00Z], status: "live", content_rev: "c1c1c1c1c1c1"},
        %{inserted_at: ~U[2026-08-06 23:02:00Z], status: "live", content_rev: nil},
        %{inserted_at: ~U[2026-08-06 23:03:00Z], status: "deferred", content_rev: "c2c2c2c2c2c2"}
      ])

      straddling_site = site_fixture()

      deployments!(straddling_site, [
        %{inserted_at: ~U[2026-08-06 22:00:00Z], status: "deferred", content_rev: "d1d1d1d1d1d1"},
        %{inserted_at: ~U[2026-08-06 22:50:00Z], status: "live", content_rev: "d1d1d1d1d1d1"}
      ])

      lines =
        DeployLedger.journeys(@from, @to,
          as_of: @as_of,
          site_ids: [pre_site.id, unmetered_site.id, post_site.id, straddling_site.id]
        )
        |> DeployLedger.journey_report()

      assert Enum.drop(lines, 6) == [
               "  PRE-DOOR (run ended before the boundary)",
               "    live-terminated  : 2.00 attempts over 3 journeys (6 attempts; 1 UNMETERED journeys excluded)",
               "    contended subset : 4.00 attempts over 1 journeys (4 attempts; 1 UNMETERED journeys excluded)",
               "    failed-terminated: 2.00 attempts over 1 journeys (2 attempts; 0 UNMETERED journeys excluded)",
               "    open runs (no terminal row in window, never metered): 0",
               "    deferred-only    : 0 publishes settled DEFERRED-ONLY over 2026-08-06T00:00:00Z -> 2026-08-07T00:00:00Z (0 superseded by a later live row — D212 benign; 0 unsuperseded); 0 not yet settled at 2026-08-07T12:00:00Z, EXCLUDED as right-censored — ABSOLUTE counts, never a rate",
               "  POST-DOOR (run began at or after the boundary)",
               "    live-terminated  : 2.00 attempts over 1 journeys (2 attempts; 1 UNMETERED journeys excluded)",
               "    contended subset : 2.00 attempts over 1 journeys (2 attempts; 0 UNMETERED journeys excluded)",
               "    failed-terminated: REFUSED over 0 journeys (0 UNMETERED journeys excluded)",
               "    open runs (no terminal row in window, never metered): 1",
               "    deferred-only    : 1 publishes settled DEFERRED-ONLY over 2026-08-06T00:00:00Z -> 2026-08-07T00:00:00Z (0 superseded by a later live row — D212 benign; 1 unsuperseded); 0 not yet settled at 2026-08-07T12:00:00Z, EXCLUDED as right-censored — ABSOLUTE counts, never a rate",
               "  STRADDLING (began before the door, ended after — its own bucket, never a side)",
               "    live-terminated  : 2.00 attempts over 1 journeys (2 attempts; 0 UNMETERED journeys excluded)",
               "    contended subset : 2.00 attempts over 1 journeys (2 attempts; 0 UNMETERED journeys excluded)",
               "    failed-terminated: REFUSED over 0 journeys (0 UNMETERED journeys excluded)",
               "    open runs (no terminal row in window, never metered): 0",
               "    deferred-only    : 0 publishes settled DEFERRED-ONLY over 2026-08-06T00:00:00Z -> 2026-08-07T00:00:00Z (0 superseded by a later live row — D212 benign; 0 unsuperseded); 0 not yet settled at 2026-08-07T12:00:00Z, EXCLUDED as right-censored — ABSOLUTE counts, never a rate"
             ]

      # The six header lines the drop above skipped are the ones carrying the
      # window, the segmentation rule, the basis, the unmetered rule and the
      # door — asserted for PRESENCE here so the drop count cannot silently
      # start swallowing a cohort line.
      assert length(lines) == 24
      assert Enum.at(lines, 1) =~ "window        : 2026-08-06T00:00:00Z -> 2026-08-07T00:00:00Z"
      assert Enum.at(lines, 5) =~ "regime door   : 2026-08-06T22:24:16Z (charter D137)"
    end
  end

  describe "the DEFERRED-ONLY publish population (charter D223)" do
    test "the population is runs of nothing but deferrals that nothing closed — not a contended release, not an in-flight run" do
      # THE UNIT IS THE PUBLISH. Under the ATTEMPT unit all three sites below
      # contribute deferred rows to one bucket and nothing tells them apart.
      stranded = site_fixture()

      deployments!(stranded, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "e1e1e1e1e1e1"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "deferred", content_rev: "e1e1e1e1e1e1"},
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "deferred", content_rev: "e1e1e1e1e1e1"}
      ])

      contended_live = site_fixture()

      deployments!(contended_live, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "e2e2e2e2e2e2"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "deferred", content_rev: "e2e2e2e2e2e2"},
        %{inserted_at: ~U[2026-08-06 10:02:00Z], status: "live", content_rev: "e2e2e2e2e2e2"}
      ])

      in_flight = site_fixture()

      deployments!(in_flight, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "e3e3e3e3e3e3"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "building", content_rev: "e3e3e3e3e3e3"}
      ])

      side = d223_side([stranded, contended_live, in_flight])

      # TWO open runs, exactly ONE of which is a deferred-only publish. An
      # `open_runs` count alone cannot make that distinction, which is why the
      # node carries both numbers.
      assert side.open_runs == 2
      assert side.deferred_only.settled.publishes == 1
      assert side.deferred_only.unsettled.publishes == 0
    end

    test "a run whose last row is younger than the settling horizon is RIGHT-CENSORED — beside the count, never inside it" do
      # The window edge is not a defect. `recent`'s last row is 20 minutes before
      # `as_of`: it has not failed to settle, it has not had time to.
      settled_site = site_fixture()

      deployments!(settled_site, [
        %{inserted_at: ~U[2026-08-06 11:00:00Z], status: "deferred", content_rev: "f1f1f1f1f1f1"}
      ])

      recent = site_fixture()

      deployments!(recent, [
        %{inserted_at: ~U[2026-08-06 11:40:00Z], status: "deferred", content_rev: "f2f2f2f2f2f2"}
      ])

      node =
        DeployLedger.journeys(@from, @to,
          as_of: ~U[2026-08-06 12:00:00Z],
          site_ids: [settled_site.id, recent.id]
        )

      side = side(node, :pre)

      assert side.open_runs == 2
      assert side.deferred_only.settled.publishes == 1
      assert side.deferred_only.unsettled.publishes == 1

      assert side.deferred_only.unsettled.excluded_because =~ "RIGHT-CENSORED"
      assert side.deferred_only.settle_rule =~ "NEVER as a rate"
    end

    test "a later live row makes it D212 BENIGN SUPERSESSION — and the probe looks BEYOND the pinned window" do
      # The superseding row is at 2026-08-07T06:00Z, OUTSIDE `@to`. That is the
      # normal shape: the publish that overtook this one happened later than the
      # window an analyst pinned. A probe bounded by `to` reads this site as a
      # stranding and manufactures loss out of the window edge.
      superseded = site_fixture()

      deployments!(superseded, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "a9a9a9a9a9a9"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "deferred", content_rev: "a9a9a9a9a9a9"},
        %{inserted_at: ~U[2026-08-07 06:00:00Z], status: "live", content_rev: "b9b9b9b9b9b9"}
      ])

      unsuperseded = site_fixture()

      deployments!(unsuperseded, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "c9c9c9c9c9c9"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "deferred", content_rev: "c9c9c9c9c9c9"}
      ])

      side = d223_side([superseded, unsuperseded])

      assert side.deferred_only.settled.publishes == 2
      assert side.deferred_only.settled.superseded == 1
      assert side.deferred_only.settled.unsuperseded == 1
      assert side.deferred_only.supersession_rule =~ "D212"
    end

    test "an EARLIER live row does not supersede — supersession is strictly after the run's last row" do
      # THE CONTROL FOR THE TEST ABOVE, and it took two sites to make it bite.
      # The supersession probe floors its query at the EARLIEST deferred-only run
      # in the population, so a single-site corpus has its pre-run live row
      # filtered out by the floor and the comparison is never exercised —
      # `superseded?/2` could answer `true` for any live row at all and the
      # suite would stay green. `early` drags the floor back to 09:30 so
      # `control`'s 09:45 live row REACHES the comparison, which is the only
      # arrangement in which `== :gt` is load-bearing.
      early = site_fixture()

      deployments!(early, [
        %{inserted_at: ~U[2026-08-06 09:29:00Z], status: "deferred", content_rev: "1a1a1a1a1a1a"},
        %{inserted_at: ~U[2026-08-06 09:30:00Z], status: "deferred", content_rev: "1a1a1a1a1a1a"}
      ])

      control = site_fixture()

      deployments!(control, [
        %{inserted_at: ~U[2026-08-06 09:45:00Z], status: "live", content_rev: "d9d9d9d9d9d9"},
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "e9e9e9e9e9e9"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "deferred", content_rev: "e9e9e9e9e9e9"}
      ])

      side = d223_side([early, control])

      assert side.deferred_only.settled.publishes == 2
      assert side.deferred_only.settled.superseded == 0
      assert side.deferred_only.settled.unsuperseded == 2
    end

    test "the node publishes COUNTS ONLY — no rate, share, fraction or percentage key anywhere in the subtree" do
      # n=163 on the corpus that motivated D223, below the @min_sample 200 floor.
      # The refusal is enforced by KEY NAME so that adding one reds here rather
      # than reaching an operator's screen as a decimal point.
      node = DeployLedger.journeys(@from, @to, as_of: @as_of, site_ids: [])

      keys =
        node.sides
        |> Enum.map(& &1.deferred_only)
        |> flatten_keys()

      assert "publishes" in keys
      assert "superseded" in keys
      assert "unsuperseded" in keys

      refute Enum.any?(
               keys,
               &(&1 =~ "rate" or &1 =~ "share" or &1 =~ "fraction" or &1 =~ "percent" or
                   &1 =~ "ratio")
             )
    end

    test "the rendered line carries the WINDOW, both splits and the word ABSOLUTE" do
      site = site_fixture()

      deployments!(site, [
        %{inserted_at: ~U[2026-08-06 10:00:00Z], status: "deferred", content_rev: "f9f9f9f9f9f9"},
        %{inserted_at: ~U[2026-08-06 10:01:00Z], status: "deferred", content_rev: "f9f9f9f9f9f9"}
      ])

      line =
        DeployLedger.journeys(@from, @to, as_of: @as_of, site_ids: [site.id])
        |> DeployLedger.journey_report()
        |> line("PRE-DOOR", "deferred-only")

      assert line ==
               "    deferred-only    : 1 publishes settled DEFERRED-ONLY over " <>
                 "2026-08-06T00:00:00Z -> 2026-08-07T00:00:00Z " <>
                 "(0 superseded by a later live row — D212 benign; 1 unsuperseded); " <>
                 "0 not yet settled at 2026-08-07T12:00:00Z, EXCLUDED as right-censored " <>
                 "— ABSOLUTE counts, never a rate"
    end
  end

  describe "the ENVIRONMENT key (a preview deploy is a DIFFERENT publish queue)" do
    # `deployments_active_site_env_index` is keyed `(site_id, environment)`, so
    # production and preview are two INDEPENDENT queues on one site: a preview
    # build never contends with a production build and never touches
    # `sites.current_deployment_id`. A run keyed on `site_id` alone therefore
    # splices two queues into one journey.
    test "a PREVIEW live row does not close a PRODUCTION run — the stranded publish stays visible" do
      site = site_fixture()

      deployments!(site, [
        %{
          inserted_at: ~U[2026-08-06 10:00:00Z],
          status: "deferred",
          content_rev: "b1b1b1b1b1b1",
          environment: "production"
        },
        %{
          inserted_at: ~U[2026-08-06 10:01:00Z],
          status: "deferred",
          content_rev: "b1b1b1b1b1b1",
          environment: "production"
        },
        # A preview build for the same site, AFTER both production deferrals. It
        # answers on its own host and says NOTHING about whether the production
        # content reached the web.
        %{
          inserted_at: ~U[2026-08-06 10:02:00Z],
          status: "live",
          content_rev: "b2b2b2b2b2b2",
          environment: "preview"
        }
      ])

      side = d223_side([site])

      # THE PRODUCTION PUBLISH IS DEFERRED-ONLY AND SETTLED. Keyed on `site_id`
      # alone the preview row TERMINATES the run: both production deferrals land
      # in a `live`-terminated journey and the D223 population reads ZERO on a
      # site whose production content never reached the web.
      assert side.deferred_only.settled.publishes == 1
      assert side.deferred_only.settled.unsuperseded == 1
      assert side.deferred_only.settled.superseded == 0
    end

    test "a later PREVIEW live row is NOT benign supersession — the production site is still not serving" do
      site = site_fixture()

      deployments!(site, [
        %{
          inserted_at: ~U[2026-08-06 10:00:00Z],
          status: "deferred",
          content_rev: "c1c1c1c1c1c1",
          environment: "production"
        },
        # Beyond `@to`, exactly like the real D212 probe expects — but on the
        # OTHER queue. Crediting it as supersession reads loss as safe, which is
        # the comforting direction and therefore the forbidden one.
        %{
          inserted_at: ~U[2026-08-07 06:00:00Z],
          status: "live",
          content_rev: "c2c2c2c2c2c2",
          environment: "preview"
        }
      ])

      side = d223_side([site])

      assert side.deferred_only.settled.publishes == 1
      assert side.deferred_only.settled.superseded == 0
      assert side.deferred_only.settled.unsuperseded == 1
    end

    # THE QUIET ARM. The environment key must not become a blanket refusal to
    # supersede: a later live row on the SAME environment is still D212 benign
    # supersession, and a same-environment live row still closes its run.
    test "a same-environment live row still closes the run AND still supersedes" do
      closed = site_fixture()

      deployments!(closed, [
        %{
          inserted_at: ~U[2026-08-06 10:00:00Z],
          status: "deferred",
          content_rev: "d1d1d1d1d1d1",
          environment: "production"
        },
        %{
          inserted_at: ~U[2026-08-06 10:01:00Z],
          status: "live",
          content_rev: "d1d1d1d1d1d1",
          environment: "production"
        }
      ])

      overtaken = site_fixture()

      deployments!(overtaken, [
        %{
          inserted_at: ~U[2026-08-06 10:00:00Z],
          status: "deferred",
          content_rev: "d2d2d2d2d2d2",
          environment: "preview"
        },
        %{
          inserted_at: ~U[2026-08-07 06:00:00Z],
          status: "live",
          content_rev: "d3d3d3d3d3d3",
          environment: "preview"
        }
      ])

      side = d223_side([closed, overtaken])

      # `closed` contributes NO deferred-only publish (its run is live-terminated
      # on its own queue); `overtaken` contributes one, SUPERSEDED.
      assert side.deferred_only.settled.publishes == 1
      assert side.deferred_only.settled.superseded == 1
      assert side.deferred_only.settled.unsuperseded == 0
    end

    test "the segmentation and the supersession rule both NAME the environment key" do
      node = DeployLedger.journeys(@from, @to, as_of: @as_of, site_ids: [])

      assert node.segmentation =~ "environment"

      side = side(node, :pre)
      assert side.deferred_only.supersession_rule =~ "environment"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp pre(site), do: site |> node_for() |> side(:pre)

  defp node_for(site), do: DeployLedger.journeys(@from, @to, site_ids: [site.id])

  # The PRE side, read at the pinned `as_of` over several sites at once — the
  # D223 tests all measure a population that spans sites.
  defp d223_side(sites) do
    DeployLedger.journeys(@from, @to, as_of: @as_of, site_ids: Enum.map(sites, & &1.id))
    |> side(:pre)
  end

  defp side(node, want), do: Enum.find(node.sides, &(&1.side == want))

  defp journey_line(site, caption) do
    site
    |> node_for()
    |> DeployLedger.journey_report()
    |> Enum.find(&(&1 =~ caption))
  end

  defp line(lines, side_caption, cohort_caption) do
    idx = Enum.find_index(lines, &(&1 =~ side_caption))

    lines
    |> Enum.drop(idx)
    |> Enum.find(&(&1 =~ cohort_caption))
  end

  # A key that names a CLOCK. `ttl` is matched as a TOKEN (whole key, or
  # underscore-delimited inside one) and never as a bare substring: as a
  # substring it fires on `settled`, `unsettled` and `settle_rule`, which are
  # counts and prose, not durations.
  defp clock_key?(key) when is_binary(key) do
    key =~ "second" or key =~ "elapsed" or "ttl" in String.split(key, "_")
  end

  defp flatten_keys(term, acc \\ [])
  defp flatten_keys(%DateTime{}, acc), do: acc

  defp flatten_keys(%{} = map, acc) do
    Enum.reduce(map, acc, fn {k, v}, a -> flatten_keys(v, [to_string(k) | a]) end)
  end

  defp flatten_keys(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &flatten_keys/2)

  defp flatten_keys(_other, acc), do: acc

  defp site_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "T #{n}", slug: "t-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})
    site
  end

  # Struct inserts, not changesets: `Deployment.changeset/2` refuses to cast
  # `status`, and a journey needs both the status and the instant pinned exactly.
  defp deployments!(site, rows) do
    entries =
      Enum.map(rows, fn r ->
        at = usec(Map.fetch!(r, :inserted_at))

        %{
          id: Ecto.UUID.generate(),
          site_id: site.id,
          status: Map.fetch!(r, :status),
          content_rev: Map.get(r, :content_rev),
          environment: Map.get(r, :environment, "production"),
          inserted_at: at,
          updated_at: at
        }
      end)

    Repo.insert_all(Deployment, entries)
  end

  defp usec(%DateTime{microsecond: {_, 6}} = dt), do: dt
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}
end
