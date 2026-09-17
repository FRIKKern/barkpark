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
  alias BarkparkCloud.Notifications.{EmailSettings, EventEmail}

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

  # A NEVER-REPORTED instance: provisioned/adopted long ago, agent has never sent
  # a byte (`last_seen_at` NULL, `agent_status` "offline", `health_status`
  # "unknown" — exactly what succeed_job/adopt now write). This is the shape
  # production carries and the shape the sweep's second arm exists to catch.
  defp never_reported_instance(team, seconds_old \\ 3600) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, %{
        name: "Never #{n}",
        slug: "never-#{n}",
        mode: "managed"
      })

    # Backdate creation past the staleness window — register_barkpark stamps
    # inserted_at with now(), and the arm is keyed on inserted_at.
    {1, _} =
      Registry.Barkpark
      |> where([b], b.id == ^bp.id)
      |> Repo.update_all(set: [inserted_at: ago(seconds_old)])

    reloaded = Registry.get_barkpark(bp.id)
    assert is_nil(reloaded.last_seen_at)
    assert reloaded.agent_status == "offline"
    reloaded
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

  # cch-w29-bl-agent-unreachable-letter-has-no-next-step
  #
  # A REAL unreachable event, driven by the REAL producer, landing in a REAL
  # mailbox — not `EventEmail.build/4` called by hand. The row's defect was that
  # the whole letter was one sentence ("<name> stopped reporting and may be
  # down.") with nothing for the reader to do, so the assertion is on the BODY
  # the worker's own dispatch put in the inbox.
  #
  # RED-ON-REVERT: delete `Render.unreachable_next_step/0` from
  # `EventEmail.render(:agent_unreachable, …)` and every `=~` below fails. Each
  # clause is asserted separately so a partial revert cannot pass on a substring
  # that happens to survive.
  test "the letter a person actually receives carries the next step" do
    {team, owner} = subscribed_team_with_owner()
    _bp = silent_online_instance(team)

    assert :ok = tick()
    assert :ok = tick()

    assert_email_sent(fn email ->
      assert email.subject == @unreachable_subject
      assert email.to == [{"", owner.email}]

      body = email.text_body

      # The fact, unchanged — the next step is ADDED, it does not replace the
      # sentence the reader already knows.
      assert body =~ "stopped reporting and may be down."

      # 1. WHAT BARKPARK ALREADY TRIED, honestly: nothing it can do more of.
      assert body =~ "Barkpark only knows what the box reports"
      assert body =~ "there is no probe that can reach in and look"
      assert body =~ "will not restart the box, retry it, or send another message"

      # 2. WHAT TO CHECK — three concrete things, on the box, in an order.
      assert body =~ "Worth checking on the box, in this order:"
      assert body =~ "the machine is powered on and on the network"
      assert body =~ "the Barkpark agent is running on it"
      assert body =~ "the agent can still reach Barkpark Cloud"

      # 3. WHAT HAPPENS IF THEY DO NOTHING, and how it ends.
      assert body =~ "If you do nothing, nothing changes here until the agent reports again."
      assert body =~ "Barkpark notices on its own and marks the instance reachable"

      # 4. AND NO INVENTED CAUSE. The producer passed a name and nothing else;
      #    the letter must not imply the plane measured why, how long, or how
      #    many ticks. This arm is what stops the next editor "helpfully"
      #    adding a reason the code never had — the exact defect this epic
      #    exists to catch.
      refute body =~ ~r/because/i
      refute body =~ ~r/\bcrash/i
      refute body =~ ~r/\bfor \d+ (second|minute|hour)/i
      refute body =~ ~r/\b\d+ (missed |health )?check/i

      # `assert_email_sent/1` asserts on the FUNCTION'S RETURN VALUE, and
      # `refute/1` returns `false` — so a trailing refute would fail the
      # assertion no matter what the body said. Every check above raises on its
      # own; this line only keeps the predicate truthy.
      true
    end)
  end

  # THE CONTROL — it stays quiet when it should.
  #
  # The next step belongs to the UNREACHABLE letter. If it ever leaks onto the
  # good-news arm, a team gets told to go check a box that just told them it is
  # fine. `:agent_reachable` is rendered by the same module off the same
  # `render/3` clause list, so this is a live sibling, not a hypothetical.
  #
  # Paired with the tick-1 test above: below the debounce gate NO mail is sent
  # at all, so the copy cannot reach anyone before the flip either.
  test "CONTROL: the recovery letter carries no next step" do
    email =
      EventEmail.build(
        %EmailSettings{},
        :agent_reachable,
        %{name: "acme"},
        "ops@example.com"
      )

    assert email.subject == "Your Barkpark is reachable again"
    assert email.text_body == "acme is reporting healthy again."
    refute email.text_body =~ "Worth checking on the box"
    refute email.text_body =~ "there is no probe"
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

  # cch-w34-s2 — the never-reported arm. Before this wave the candidate query
  # ALSO required `agent_status == "online"`, and nothing in cloud/lib writes
  # "online" without co-writing last_seen_at, so the `last_seen_at IS NULL` arm
  # its own docstring promised could not fire. Production carried 3 boxes in
  # exactly this state for 38 days with a green "up" and zero missed-heartbeat
  # counts. These tests pin that the arm is now REACHABLE — remove the
  # `is_nil(b.last_seen_at)` branch (or restore the blanket online requirement)
  # in Registry.stale_online_barkparks/1 and both of them red.
  test "a NEVER-REPORTED instance is a candidate: the counter bumps on tick 1" do
    {team, _owner} = subscribed_team_with_owner()
    bp = never_reported_instance(team)

    assert :ok = tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.unreachable_count == 1
    assert reloaded.unreachable_notification_sent == false
    refute_email_sent()
  end

  test "a NEVER-REPORTED instance crosses the gate: ONE alert, then it backs off" do
    {team, owner} = subscribed_team_with_owner()
    bp = never_reported_instance(team)

    assert :ok = tick()
    assert :ok = tick()

    flipped = Registry.get_barkpark(bp.id)
    assert flipped.unreachable_count == 2
    assert flipped.agent_status == "offline"
    assert flipped.health_status == "unknown"
    assert flipped.unreachable_notification_sent == true
    assert_email_sent(subject: @unreachable_subject, to: {"", owner.email})

    # The latch IS this arm's backoff (a never-reported row has no online status
    # to lose): tick 3 neither re-increments nor re-alerts.
    assert :ok = tick()
    settled = Registry.get_barkpark(bp.id)
    assert settled.unreachable_count == 2
    refute_email_sent()
  end

  test "a never-reported instance created INSIDE the window is not yet a candidate" do
    {team, _owner} = subscribed_team_with_owner()
    bp = never_reported_instance(team, 0)

    assert :ok = tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.unreachable_count == 0
    refute_email_sent()
  end

  test "a never-reported instance whose team is NOT subscribed is never alerted" do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    # NO Billing.subscribe — the paid-fleet gate applies to BOTH arms.
    bp = never_reported_instance(team)

    tick()
    tick()
    tick()

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.unreachable_count == 0
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
