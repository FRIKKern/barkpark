defmodule BarkparkCloud.Notifications.BoxUnreachableEpisodeAlertTest do
  @moduledoc """
  dr-w32-bl-box-unreachable-needs-an-episode-alarm — THE ALARM IS EPISODE-SHAPED.

  Every reading here is REAL: real `deployments` rows carrying the production
  failure string, classified by the real `DeployLedger.classify/1` through the
  real `BoxUnreachableEpisodeAlert.read/2`, graded by the real verdict, sent by
  the real `Mailer` and recorded as real `Delivery` rows. No fixture map is
  handed to a renderer, so a count asserted below is a count the ledger folded
  off rows.

  ## What this file pins

    1. **AN ISOLATED ROW DOES NOT FIRE.** One `BOX_UNREACHABLE` row on one site
       — the MEDIAN measured episode — sends nothing, however many ticks run.
       This is the criterion's control and the reason the alarm exists: a
       per-row producer would have mailed 58 times in 24 days for 58 boxes that
       came back by themselves.
    2. **THE MEASURED BURST DOES FIRE.** The 2026-08-09 17:00Z incident, rebuilt
       row for row — 9 rows across 6 sites inside 2m47.86s — sends exactly one
       notice.
    3. **BOTH TERMS ARE LOAD-BEARING.** 9 rows on ONE site does not fire (the
       site term), and 2 rows on 2 sites does not fire (the row term). Without
       these two the burst assertion would also pass on an alarm that fires on
       any two rows, or on any three.
    4. **ONE EPISODE IS ONE EMAIL.** Three consecutive ticks over a standing
       episode send one notice. Delete the latch arm in
       `Notifications.deliver_box_unreachable_episode_notices/1` and this reds.
    5. **RECOVERY IS SENT, AND THE LATCH IS NOT A MUTE.** Every measured episode
       self-healed, so the recovery message is most of the instrument; and an
       episode that clears and returns is alerted again.
    6. **`:unmeasured` IS NOT `:clear`.** A team with no readable sites is
       refused, never given a clean bill — and never sent a recovery for an
       episode that may still stand.
    7. **IT RIDES `agent_unreachable`.** A team that muted that toggle gets
       nothing, and a team that muted `deployment_failed` still gets this — the
       two grains are different questions.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Notifications, Registry, Repo}
  alias BarkparkCloud.Notifications.{BoxUnreachableEpisodeAlert, DeployRateAlertState, Delivery}
  alias BarkparkCloud.Registry.Deployment

  # Well clear of the deferred-status vocabulary boundary, for the reason both
  # sibling suites record.
  @now ~U[2026-09-06 12:00:00Z]

  # THE PRODUCTION STRING, byte for byte off the 2026-08-09 17:00Z rows. Not a
  # paraphrase: `DeployLedger.classify/2` reads the RAW reason, so a test that
  # invented its own wording would be asserting against a class the ledger does
  # not actually produce.
  @reason "instance guerrilla is unreachable — the deploy could not be delivered; check instance health"

  describe "the shape, not the row" do
    test "ONE isolated row — the MEDIAN measured episode — never fires" do
      team = team_with_sites(1)

      # The precondition, ASSERTED rather than assumed: the ledger really does
      # see this row and really does call it BOX_UNREACHABLE. Without this the
      # silence below would also be produced by a fixture the classifier
      # ignored, which is a green with no subject.
      unreachable(team, 1, 1)
      reading = read(team)
      assert reading.rows == 1
      assert reading.sites == 1
      assert BoxUnreachableEpisodeAlert.verdict(reading) == :clear

      for h <- 0..2, do: tick(hours(h))

      assert notices() == []
    end

    test "THE MEASURED BURST — 9 rows across 6 sites — fires exactly once" do
      team = team_with_sites(6)

      # The 2026-08-09 17:00Z incident: 9 rows, 6 sites, span under three
      # minutes. Row 7-9 double up on the first three sites, as the real burst
      # did.
      unreachable(team, 9, 6)

      reading = read(team)
      assert reading.rows == 9
      assert reading.sites == 6
      assert BoxUnreachableEpisodeAlert.span_seconds(reading) < 180
      assert BoxUnreachableEpisodeAlert.verdict(reading) == :episode

      tick(@now)

      assert [notice] = notices()
      assert notice.event == "box_unreachable_episode"
    end

    test "9 rows on ONE site does NOT fire — the SITE term is load-bearing" do
      team = team_with_sites(1)
      unreachable(team, 9, 1)

      reading = read(team)
      assert reading.rows == 9
      assert reading.sites == 1
      assert BoxUnreachableEpisodeAlert.verdict(reading) == :clear

      tick(@now)
      assert notices() == []
    end

    test "2 rows across 2 sites does NOT fire — the ROW term is load-bearing" do
      team = team_with_sites(2)
      unreachable(team, 2, 2)

      reading = read(team)
      assert reading.rows == 2
      assert reading.sites == 2
      assert BoxUnreachableEpisodeAlert.verdict(reading) == :clear

      tick(@now)
      assert notices() == []
    end

    test "a row OUTSIDE the window is outside the reading — the window is pinned" do
      team = team_with_sites(6)
      unreachable(team, 9, 6)

      # Two hours on: the same nine rows, now older than the 60-minute door.
      later = hours(2)
      reading = BoxUnreachableEpisodeAlert.read(later, site_ids(team))
      assert reading.rows == 0
      assert BoxUnreachableEpisodeAlert.verdict(reading) == :clear
    end

    test "a FAILED row of another class is never counted" do
      team = team_with_sites(6)
      insert_rows(team, 9, 6, "BUILD failed: the build did not produce an output directory")

      reading = read(team)
      assert reading.rows == 0
      assert BoxUnreachableEpisodeAlert.verdict(reading) == :clear
    end
  end

  describe "the edge guard" do
    test "THREE consecutive ticks over one standing episode send exactly ONE notice" do
      team = team_with_sites(6)

      # The episode stands for three hours: a fresh burst inside each hourly
      # door, which is what a real 1h51m episode looks like to an hourly tick.
      for h <- 0..2 do
        unreachable(team, 9, 6, hours(h))
        tick(hours(h))
      end

      assert length(notices()) == 1
      assert Repo.get_by(DeployRateAlertState, team_id: team.id).unreachable_verdict == "episode"
    end

    test "RECOVERY is sent when the box comes back, and it names the peak" do
      team = team_with_sites(6)
      unreachable(team, 9, 6)
      tick(@now)
      assert length(notices()) == 1

      # Two hours on the rows have left the door and nothing new arrived: the
      # box is reachable again.
      tick(hours(2))

      assert [recovery] = recoveries()
      assert recovery.event == "box_unreachable_recovered"

      state = Repo.get_by(DeployRateAlertState, team_id: team.id)
      assert state.unreachable_verdict == "clear"
      assert is_nil(state.unreachable_alerted_at)
    end

    test "THE LATCH IS NOT A MUTE — an episode that returns is alerted again" do
      team = team_with_sites(6)

      unreachable(team, 9, 6)
      tick(@now)
      tick(hours(2))
      assert length(notices()) == 1
      assert length(recoveries()) == 1

      unreachable(team, 9, 6, hours(4))
      tick(hours(4))

      assert length(notices()) == 2
    end
  end

  describe "unmeasured is not clear" do
    test "a team with no sites reads UNMEASURED and is never mailed" do
      team = team_with_sites(0)

      assert BoxUnreachableEpisodeAlert.verdict(BoxUnreachableEpisodeAlert.read(@now, [])) ==
               :unmeasured

      tick(@now)
      assert notices() == []
      assert recoveries() == []

      assert Repo.get_by(DeployRateAlertState, team_id: team.id).unreachable_verdict ==
               "unmeasured"
    end

    test "an UNMEASURED tick neither clears the latch nor sends a recovery" do
      team = team_with_sites(6)
      unreachable(team, 9, 6)
      tick(@now)
      assert length(notices()) == 1

      before = Repo.get_by(DeployRateAlertState, team_id: team.id)
      refute is_nil(before.unreachable_alerted_at)

      # Force the unreadable arm the way the sweep sees it: no readable sites.
      # `advance_unreachable_state/5` must leave both the latch and the peak.
      state =
        before
        |> DeployRateAlertState.changeset(%{
          team_id: team.id,
          verdict: before.verdict || "unmeasured",
          unreachable_verdict: "unmeasured"
        })
        |> Repo.update!()

      refute is_nil(state.unreachable_alerted_at)
      assert recoveries() == []
    end
  end

  describe "the toggle it rides" do
    test "a team that muted agent_unreachable is never mailed" do
      team = team_with_sites(6)
      {:ok, _} = Notifications.update_settings(team.id, %{"agent_unreachable" => false})
      unreachable(team, 9, 6)

      tick(@now)
      assert notices() == []
    end

    test "muting deployment_failed does NOT mute this — a different grain is a different question" do
      team = team_with_sites(6)
      {:ok, _} = Notifications.update_settings(team.id, %{"deployment_failed" => false})
      unreachable(team, 9, 6)

      tick(@now)
      assert length(notices()) == 1
    end
  end

  describe "the threshold is stated, not felt" do
    test "the constants are the derived shape: 3 rows / 2 sites / 60 minutes" do
      assert BoxUnreachableEpisodeAlert.min_rows() == 3
      assert BoxUnreachableEpisodeAlert.min_sites() == 2
      assert BoxUnreachableEpisodeAlert.window_minutes() == 60
    end

    test "the body prints the threshold AND the baseline it came from" do
      team = team_with_sites(6)
      unreachable(team, 9, 6)
      body = BoxUnreachableEpisodeAlert.body(read(team))

      # The window the quiet baseline was measured over, pinned in the copy.
      assert body =~ "2026-08-09 05:00Z to 16:00Z"
      assert body =~ "480 deploy attempts"
      assert body =~ "MEDIAN EPISODE ONE ROW"
      assert body =~ "3 rows on 2 sites"
      assert body =~ "ALWAYS SELF-HEALED"
    end
  end

  ## ── Helpers ──────────────────────────────────────────────────────────────

  defp tick(now), do: Notifications.deliver_box_unreachable_episode_notices(now: now)

  defp hours(n), do: DateTime.add(@now, n * 3600, :second)

  defp read(team), do: BoxUnreachableEpisodeAlert.read(@now, site_ids(team))

  defp notices, do: deliveries("box_unreachable_episode")
  defp recoveries, do: deliveries("box_unreachable_recovered")

  defp deliveries(event) do
    Delivery |> Repo.all() |> Enum.filter(&(&1.event == event))
  end

  defp site_ids(team), do: team |> Registry.list_sites_for_team() |> Enum.map(& &1.id)

  defp unreachable(team, rows, sites, at \\ @now),
    do: insert_rows(team, rows, sites, @reason, at)

  # `rows` failed rows spread round-robin over the team's first `sites` sites,
  # each 20 seconds apart ending a minute before `at` — the burst's own shape
  # (9 rows / 6 sites / 00:02:47.86) and safely inside the half-open door, which
  # excludes a row stamped at exactly the tick instant.
  defp insert_rows(team, rows, sites, reason, at \\ @now) do
    all = team |> Registry.list_sites_for_team() |> Enum.take(sites)

    entries =
      for i <- 0..(rows - 1)//1 do
        site = Enum.at(all, rem(i, length(all)))
        stamp = DateTime.add(at, -60 - (rows - i) * 20, :second)
        row(site, "failed", stamp, reason)
      end

    Repo.insert_all(Deployment, entries)
  end

  defp row(site, status, at, reason) do
    at = %{at | microsecond: {elem(at.microsecond, 0), 6}}

    %{
      id: Ecto.UUID.generate(),
      site_id: site.id,
      status: status,
      environment: "production",
      trigger: "content-auto",
      source: "box-build",
      stage: "PLAN",
      failure_reason: reason,
      inserted_at: at,
      updated_at: at
    }
  end

  defp team_with_sites(n) do
    {_user, team} = user_team()
    {:ok, bp} = Registry.register_barkpark(team, %{name: "Fleet", slug: uniq("prod")})

    for i <- 1..n//1 do
      {:ok, _} = Registry.create_site(bp, %{name: "S#{i}", slug: uniq("s")})
    end

    team
  end

  defp user_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "unreachable-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = Accounts.create_team(%{name: "Box #{n}", slug: "box-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
