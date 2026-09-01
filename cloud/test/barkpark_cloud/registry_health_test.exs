defmodule BarkparkCloud.RegistryHealthTest do
  @moduledoc """
  The staleness-detection seam in the Registry context (health-status): the
  candidate scan, the missed-heartbeat bump, the offline flip, and the
  recovery-on-report reset. These back BarkparkCloud.Health.StalenessWorker.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Registry.AgentEvent

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  # A team with an ACTIVE subscription — the staleness scan only considers
  # subscribed teams (Coolify's stripe_invoice_paid gate).
  defp subscribed_team(attrs \\ %{}) do
    team = team_fixture(attrs)
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    team
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(
        team,
        Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"})
      )

    bp
  end

  # Seconds-ago helper for backdating last_seen_at.
  defp ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:microsecond)
  end

  describe "stale_online_barkparks/1" do
    setup do
      # 5-minutes-ago threshold: anything last seen before this is "stale".
      %{threshold: ago(300)}
    end

    test "returns an online, subscribed, managed instance silent past the threshold",
         %{threshold: threshold} do
      team = subscribed_team()

      bp =
        barkpark_fixture(team, %{mode: "managed", agent_status: "online", last_seen_at: ago(600)})

      ids = Registry.stale_online_barkparks(threshold) |> Enum.map(& &1.id)
      assert bp.id in ids
    end

    test "excludes an instance whose team has NO active subscription",
         %{threshold: threshold} do
      team = team_fixture()

      _bp =
        barkpark_fixture(team, %{mode: "managed", agent_status: "online", last_seen_at: ago(600)})

      assert Registry.stale_online_barkparks(threshold) == []
    end

    test "excludes an already-offline instance (the natural backoff)",
         %{threshold: threshold} do
      team = subscribed_team()

      _bp =
        barkpark_fixture(team, %{mode: "managed", agent_status: "offline", last_seen_at: ago(600)})

      assert Registry.stale_online_barkparks(threshold) == []
    end

    test "excludes a FRESH heartbeat (seen after the threshold)",
         %{threshold: threshold} do
      team = subscribed_team()

      _bp =
        barkpark_fixture(team, %{mode: "managed", agent_status: "online", last_seen_at: ago(10)})

      assert Registry.stale_online_barkparks(threshold) == []
    end

    test "excludes a self_hosted instance (we don't operate it)",
         %{threshold: threshold} do
      team = subscribed_team()

      _bp =
        barkpark_fixture(team, %{
          mode: "self_hosted",
          agent_status: "online",
          last_seen_at: ago(600)
        })

      assert Registry.stale_online_barkparks(threshold) == []
    end

    test "includes a never-reported (last_seen_at nil) row created before the threshold",
         %{threshold: threshold} do
      team = subscribed_team()
      # No last_seen_at; the row's inserted_at is now, so it should NOT be caught
      # by a threshold in the past — but a row inserted before the threshold is.
      bp = barkpark_fixture(team, %{mode: "managed", agent_status: "online"})

      # Fresh insert (inserted_at == now) is NOT past a 5-min-ago threshold.
      refute bp.id in (Registry.stale_online_barkparks(threshold) |> Enum.map(& &1.id))

      # A threshold in the FUTURE makes the just-inserted row count as old.
      future = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)
      assert bp.id in (Registry.stale_online_barkparks(future) |> Enum.map(& &1.id))
    end
  end

  describe "bump_unreachable/1" do
    test "increments and persists the counter" do
      team = subscribed_team()
      bp = barkpark_fixture(team, %{agent_status: "online"})
      assert bp.unreachable_count == 0

      {:ok, bumped} = Registry.bump_unreachable(bp)
      assert bumped.unreachable_count == 1

      {:ok, again} = Registry.bump_unreachable(bumped)
      assert again.unreachable_count == 2
      assert Registry.get_barkpark(bp.id).unreachable_count == 2
    end
  end

  describe "mark_offline/1" do
    test "flips agent offline + health unknown and latches the alert flag" do
      team = subscribed_team()
      bp = barkpark_fixture(team, %{agent_status: "online", health_status: "up"})

      {:ok, offline} = Registry.mark_offline(bp)
      assert offline.agent_status == "offline"
      assert offline.health_status == "unknown"
      assert offline.unreachable_notification_sent == true
    end
  end

  describe "record_agent_report/2" do
    test "resets the counter + clears the latch, returns {:ok, bp} when not latched" do
      team = subscribed_team()
      bp = barkpark_fixture(team, %{agent_status: "online"})
      {:ok, bumped} = Registry.bump_unreachable(bp)
      assert bumped.unreachable_count == 1

      assert {:ok, reset} =
               Registry.record_agent_report(bumped, %{
                 health_status: "up",
                 agent_status: "online",
                 last_seen_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
               })

      assert reset.unreachable_count == 0
      assert reset.unreachable_notification_sent == false
    end

    test "returns {:recovered, bp} when the row was latched (an outage just ended)" do
      team = subscribed_team()
      bp = barkpark_fixture(team, %{agent_status: "online"})
      {:ok, offline} = Registry.mark_offline(bp)
      assert offline.unreachable_notification_sent == true

      assert {:recovered, recovered} =
               Registry.record_agent_report(offline, %{
                 health_status: "up",
                 agent_status: "online",
                 last_seen_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
               })

      assert recovered.unreachable_count == 0
      assert recovered.unreachable_notification_sent == false
      assert recovered.agent_status == "online"
    end
  end

  # dr-w22-bl — SINCE WHEN this box has served the sha it serves now.
  #
  # THE HOLE THIS CLOSES. The `(sha, first_seen)` history already existed:
  # every 60 s beat is inserted append-only into `agent_events` with the FULL
  # report (`git_commit` included) and AgentRetentionWorker keeps 14 days of it.
  # MEASURED on prod 2026-09-01 — 132,120 rows, 2026-08-18T03:30:20Z ->
  # 2026-09-01T23:19:22Z, and 7 completed AgentRetentionWorker jobs. But its
  # only reader is `GET /v1/barkparks/:id/events`, which is `Auth.require_user`
  # and caps a page at 200 rows: about three hours of a fourteen-day record,
  # handed to a NARROWER caller than the `require_user_or_pat` fleet list.
  #
  # The stamp is deliberately conservative in both refusals, and the two REFUSAL
  # tests below are the load-bearing half: a "first seen" that re-stamps every
  # 60 s is a last-seen under a false name, and one that dates an unobserved
  # transition reports a weeks-old commit as freshly deployed.
  describe "record_agent_report/2 — git_commit_first_seen_at" do
    defp beat(bp, sha) do
      Registry.record_agent_report(bp, %{
        health_status: "up",
        agent_status: "online",
        git_commit: sha,
        last_seen_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
      })
    end

    test "the first beat carrying a DIFFERENT sha stamps the first-seen" do
      team = subscribed_team()
      bp = barkpark_fixture(team, %{agent_status: "online", git_commit: String.duplicate("a", 40)})
      assert bp.git_commit_first_seen_at == nil

      before = DateTime.utc_now()
      assert {:ok, stamped} = beat(bp, String.duplicate("b", 40))

      assert stamped.git_commit == String.duplicate("b", 40)
      assert stamped.git_commit_first_seen_at != nil
      # The stamp dates THIS beat, not some other instant.
      assert DateTime.compare(stamped.git_commit_first_seen_at, before) in [:gt, :eq]
      assert DateTime.compare(stamped.git_commit_first_seen_at, DateTime.utc_now()) in [:lt, :eq]
    end

    test "a SAME-sha beat does NOT re-stamp — a re-stamp would be last_seen under a false name" do
      team = subscribed_team()
      sha = String.duplicate("c", 40)
      bp = barkpark_fixture(team, %{agent_status: "online", git_commit: String.duplicate("d", 40)})

      assert {:ok, stamped} = beat(bp, sha)
      first = stamped.git_commit_first_seen_at
      assert first != nil

      # Three more steady beats — the shape a healthy box has every 60 s.
      assert {:ok, again} = beat(stamped, sha)
      assert {:ok, again} = beat(again, sha)
      assert {:ok, again} = beat(again, sha)

      assert again.git_commit_first_seen_at == first
    end

    test "a box that has never been seen CHANGING sha reads nil — nil is UNMEASURED, never now" do
      team = subscribed_team()
      sha = String.duplicate("e", 40)
      bp = barkpark_fixture(team, %{agent_status: "online", git_commit: sha})

      assert {:ok, unchanged} = beat(bp, sha)
      assert unchanged.git_commit == sha
      assert unchanged.git_commit_first_seen_at == nil

      # The SECOND refusal, and the subtler one: a row whose stored sha is blank
      # (a fresh row, an offline agent, an agent predating `git_commit` in the
      # report). The arriving commit may have been running for days before the
      # first beat carrying it reached us, so the transition is not DATED — it is
      # merely noticed. Stamping `now` here would report a weeks-old commit as
      # freshly deployed, in a brand-new column, which is the exact unearned
      # green this contract exists to refuse.
      blank = barkpark_fixture(team, %{agent_status: "online"})
      assert blank.git_commit in [nil, ""]
      assert {:ok, first_ever} = beat(blank, sha)
      assert first_ever.git_commit == sha
      assert first_ever.git_commit_first_seen_at == nil
    end

    test "the column is SERVER-COMPUTED: a caller-supplied stamp is dropped, both spellings" do
      team = subscribed_team()
      team2 = subscribed_team()
      forged = ~U[2001-01-01 00:00:00.000000Z]

      # A beat that does NOT change the sha cannot smuggle a stamp in.
      sha = String.duplicate("f", 40)
      bp = barkpark_fixture(team, %{agent_status: "online", git_commit: sha})

      assert {:ok, atom_key} =
               Registry.record_agent_report(bp, %{
                 health_status: "up",
                 agent_status: "online",
                 git_commit: sha,
                 git_commit_first_seen_at: forged,
                 last_seen_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
               })

      assert atom_key.git_commit_first_seen_at == nil

      # And a beat that DOES change the sha stamps the SERVER's instant over the
      # forged one, not the forged one. String spelling, the shape a raw body
      # would arrive in.
      bp2 = barkpark_fixture(team2, %{agent_status: "online", git_commit: sha})

      assert {:ok, string_key} =
               Registry.record_agent_report(bp2, %{
                 "health_status" => "up",
                 "agent_status" => "online",
                 "git_commit" => String.duplicate("9", 40),
                 "git_commit_first_seen_at" => forged,
                 "last_seen_at" => DateTime.truncate(DateTime.utc_now(), :microsecond)
               })

      assert string_key.git_commit_first_seen_at != nil
      assert DateTime.compare(string_key.git_commit_first_seen_at, forged) == :gt
    end
  end

  describe "recent_events_for_team/3" do
    test "returns the instance's events newest-first for the owning team" do
      team = subscribed_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.record_event(bp, "health", %{n: 1})
      {:ok, _} = Registry.record_event(bp, "status", %{transition: "offline"})

      events = Registry.recent_events_for_team(team, bp.id, 50)
      assert [%AgentEvent{type: "status"}, %AgentEvent{type: "health"}] = events
    end

    test "returns nil for another team's instance (no existence leak)" do
      owner = subscribed_team()
      other = team_fixture()
      bp = barkpark_fixture(owner)
      {:ok, _} = Registry.record_event(bp, "health", %{n: 1})

      assert Registry.recent_events_for_team(other, bp.id, 50) == nil
    end

    test "returns nil for a nonexistent (and malformed) id" do
      team = subscribed_team()
      assert Registry.recent_events_for_team(team, Ecto.UUID.generate(), 50) == nil
      assert Registry.recent_events_for_team(team, "not-a-uuid", 50) == nil
    end
  end
end
