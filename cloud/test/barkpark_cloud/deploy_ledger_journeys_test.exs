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

      node = DeployLedger.journeys(@from, @to, site_ids: [before_door.id, after_door.id, across.id])

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

      refute node
             |> flatten_keys()
             |> Enum.any?(&(&1 =~ "second" or &1 =~ "elapsed" or &1 =~ "ttl"))
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp pre(site), do: site |> node_for() |> side(:pre)

  defp node_for(site), do: DeployLedger.journeys(@from, @to, site_ids: [site.id])

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
