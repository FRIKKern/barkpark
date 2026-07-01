defmodule BarkparkCloud.Health.StalenessWorkerTest do
  @moduledoc """
  The per-minute staleness sweep (health-status). Drives the worker directly via
  `StalenessWorker.perform(%Oban.Job{})` (Oban is `testing: :manual`, so the cron
  never self-fires) and asserts: the debounce gate, the offline flip + ONE alert,
  the idempotent backoff, the subscription gate, latch re-arm on recovery, and
  the two best-effort-mail invariants (a delivery failure does not roll back the
  flip; a team with no recipients flips silently).

  Re-pointed onto main's platform `Notifications` context: the offline flip fires
  `dispatch_event(team_id, :agent_unreachable, …)` — the same first-class,
  per-team-opt-in event the report-flip path uses — and delivery lands in the
  `Swoosh.Adapters.Test` mailbox for `Swoosh.TestAssertions`.

  `async: false`: one test swaps the platform Mailer adapter to a failing one to
  exercise the delivery-failure invariant, so this module must not run
  concurrently with other suites that assert on sent mail.
  """
  use BarkparkCloud.DataCase, async: false
  import Swoosh.TestAssertions

  alias BarkparkCloud.{Accounts, Billing, Notifications, Registry}
  alias BarkparkCloud.Health.StalenessWorker

  @unreachable_subject "Your Barkpark is unreachable"

  # A Swoosh adapter that ALWAYS fails delivery — used to prove the status flip is
  # committed independent of mail success (the best-effort-mail invariant).
  defmodule BoomAdapter do
    use Swoosh.Adapter

    @impl Swoosh.Adapter
    def deliver(_email, _config), do: {:error, {:boom, :relay_down}}
  end

  setup do
    # Make the debounce cheap + deterministic: a 1-second staleness window, a
    # 2-tick down-count. Restored after the test.
    prev_stale = Application.get_env(:barkpark_cloud, :health_stale_after_seconds)
    prev_count = Application.get_env(:barkpark_cloud, :health_down_after_count)
    Application.put_env(:barkpark_cloud, :health_stale_after_seconds, 1)
    Application.put_env(:barkpark_cloud, :health_down_after_count, 2)

    on_exit(fn ->
      restore(:health_stale_after_seconds, prev_stale)
      restore(:health_down_after_count, prev_count)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark_cloud, key)
  defp restore(key, val), do: Application.put_env(:barkpark_cloud, key, val)

  # A subscribed team whose OWNER is a member (so alerts have a recipient).
  defp subscribed_team_with_owner do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "owner-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    {team, user}
  end

  # An online instance whose last heartbeat is well past the 1s staleness window.
  defp silent_online_instance(team) do
    n = System.unique_integer([:positive])
    old = ago(3600)

    {:ok, bp} =
      Registry.register_barkpark(team, %{
        name: "BP #{n}",
        slug: "bp-#{n}",
        mode: "managed",
        agent_status: "online",
        health_status: "up",
        last_seen_at: old
      })

    bp
  end

  defp ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:microsecond)
  end

  defp tick, do: StalenessWorker.perform(%Oban.Job{})

  test "tick 1 bumps the counter but does not flip or alert (the debounce gate)" do
    {team, _owner} = subscribed_team_with_owner()
    bp = silent_online_instance(team)

    assert :ok = tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.unreachable_count == 1
    assert reloaded.agent_status == "online"
    assert reloaded.health_status == "up"
    assert reloaded.unreachable_notification_sent == false
    refute_email_sent()
  end

  test "tick 2 crosses the gate: flips offline, records a status event, sends ONE alert" do
    {team, owner} = subscribed_team_with_owner()
    bp = silent_online_instance(team)

    assert :ok = tick()
    assert :ok = tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.agent_status == "offline"
    assert reloaded.health_status == "unknown"
    assert reloaded.unreachable_notification_sent == true

    # A "status" transition event was appended.
    events = Registry.recent_events(bp.id, 10)
    assert Enum.any?(events, &(&1.type == "status" and &1.payload["transition"] == "offline"))

    # An :agent_unreachable alert went to the team owner (main's Notifications
    # dispatch → team members).
    assert_email_sent(subject: @unreachable_subject, to: {"", owner.email})
  end

  test "tick 3 is a no-op: the now-offline row is no longer a candidate (backoff)" do
    {team, _owner} = subscribed_team_with_owner()
    bp = silent_online_instance(team)

    tick()
    tick()
    # Drain the offline alert from tick 2 so the next assertion is clean.
    assert_email_sent(subject: @unreachable_subject)

    before = Registry.get_barkpark(bp.id)
    assert :ok = tick()
    after_ = Registry.get_barkpark(bp.id)

    # No second flip, no re-increment, no second alert.
    assert after_.unreachable_count == before.unreachable_count
    assert after_.agent_status == "offline"
    refute_email_sent()
  end

  test "an instance whose team is NOT subscribed is never flipped or alerted" do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    {:ok, user} =
      Accounts.register_user(%{
        email: "owner-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, _} = Accounts.add_member(team, user, "owner")
    # NO Billing.subscribe — the team is unsubscribed, so it never enters the scan.
    bp = silent_online_instance(team)

    tick()
    tick()
    tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.agent_status == "online"
    assert reloaded.unreachable_count == 0
    refute_email_sent()
  end

  test "recovery RE-ARMS the latch: a report after an outage lets a LATER outage alert again" do
    {team, _owner} = subscribed_team_with_owner()
    bp = silent_online_instance(team)

    # First outage → one alert, latched.
    tick()
    tick()
    assert_email_sent(subject: @unreachable_subject)

    offline = Registry.get_barkpark(bp.id)
    assert offline.unreachable_notification_sent == true

    # The agent reports again — record_agent_report/2 clears the latch (the
    # router's POST /v1/agent/report wiring).
    assert {:recovered, recovered} =
             Registry.record_agent_report(offline, %{
               health_status: "up",
               agent_status: "online",
               last_seen_at: ago(0)
             })

    assert recovered.unreachable_count == 0
    assert recovered.unreachable_notification_sent == false

    # Backdate the heartbeat so the box is a stale candidate once more.
    {:ok, _} = Registry.upsert_health(recovered, %{last_seen_at: ago(3600)})

    # SECOND outage → a SECOND alert fires. Only possible because the latch was
    # re-armed; if record_agent_report had left the latch set, this flip (and its
    # email) would never happen.
    tick()
    tick()
    assert_email_sent(subject: @unreachable_subject)

    reflipped = Registry.get_barkpark(bp.id)
    assert reflipped.agent_status == "offline"
    assert reflipped.unreachable_notification_sent == true
  end

  test "a mail delivery FAILURE does not block or roll back the offline flip" do
    prev = Application.get_env(:barkpark_cloud, BarkparkCloud.Mailer)
    Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, adapter: BoomAdapter)
    on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, prev) end)

    {team, _owner} = subscribed_team_with_owner()
    bp = silent_online_instance(team)

    # Even though every delivery errors, the worker completes and the flip commits.
    assert :ok = tick()
    assert :ok = tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.agent_status == "offline"
    assert reloaded.health_status == "unknown"
    assert reloaded.unreachable_notification_sent == true

    # The delivery was attempted and recorded as FAILED — proving the flip
    # persisted DESPITE a real send failure (best-effort mail), not because no
    # send was attempted.
    assert Enum.any?(Notifications.list_deliveries(team), &(&1.status == "failed"))
  end

  test "a subscribed team with NO recipients flips silently (no raise, zero emails)" do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    # No members at all — dispatch resolves an empty recipient set.
    bp = silent_online_instance(team)

    assert :ok = tick()
    assert :ok = tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.agent_status == "offline"
    assert reloaded.unreachable_notification_sent == true
    refute_email_sent()
  end
end
