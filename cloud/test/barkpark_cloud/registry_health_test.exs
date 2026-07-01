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
