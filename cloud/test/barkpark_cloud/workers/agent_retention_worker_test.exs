defmodule BarkparkCloud.Workers.AgentRetentionWorkerTest do
  @moduledoc """
  azh-w6 — the daily retention pruner for the two unbounded agent tables.

  Deterministic without a clock library: rows are BACKDATED to explicit ages
  (via `Repo.update_all`, the reaper-test idiom) so `perform/1`'s real
  `DateTime.utc_now()` sees a frozen relative timeline. Survivorship is asserted
  exactly — nothing near the boundary is pruned, everything past it is.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs) —
  `perform_job/2` runs synchronously inside this test's sandboxed transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, PlatformDelivery, Registry, Usage}
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Registry.{AgentEvent, AgentToken}
  alias BarkparkCloud.Usage.Sample
  alias BarkparkCloud.Workers.AgentRetentionWorker

  ## Fixtures (mirror StaleProvisionJobReaperTest)

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp days_ago(n) do
    DateTime.utc_now() |> DateTime.add(-n * 24 * 3600, :second) |> DateTime.truncate(:microsecond)
  end

  # Record a health event, then backdate its inserted_at to `days` old.
  defp aged_event(bp, days) do
    {:ok, ev} = Registry.record_event(bp, "health", %{})

    {1, _} =
      Repo.update_all(from(e in AgentEvent, where: e.id == ^ev.id),
        set: [inserted_at: days_ago(days)]
      )

    ev.id
  end

  ## 1. Cron wiring — scheduled DAILY on the maintenance queue.

  test "worker is registered daily on the maintenance queue" do
    crontab =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"30 3 * * *", AgentRetentionWorker} in crontab
    assert Ecto.Changeset.get_field(AgentRetentionWorker.new(%{}), :queue) == "maintenance"
  end

  ## 2. agent_events — older than 14 days pruned, the window kept.

  test "prunes agent_events older than 14 days and keeps the window" do
    team = team_fixture()
    bp = barkpark_fixture(team)

    old1 = aged_event(bp, 20)
    old2 = aged_event(bp, 15)
    # Exactly at the boundary and inside it — both survive.
    keep_boundary = aged_event(bp, 13)
    keep_fresh = aged_event(bp, 1)

    assert {:ok, %{events_deleted: 2}} = perform_job(AgentRetentionWorker, %{})

    refute Repo.get(AgentEvent, old1)
    refute Repo.get(AgentEvent, old2)
    assert Repo.get(AgentEvent, keep_boundary)
    assert Repo.get(AgentEvent, keep_fresh)
  end

  ## 3. agent_tokens — dead >30d pruned; live + recently-dead kept.

  test "prunes agent_tokens 30+ days past revoked_at, keeps live and recently-revoked" do
    team = team_fixture()
    bp = barkpark_fixture(team)

    # A live token (never revoked, no expiry) — must survive untouched.
    {:ok, _pt_live, live} = Registry.mint_agent_token(bp, "live-scope")

    # Long-dead: revoked 40 days ago.
    {:ok, _pt_a, old_revoked} = Registry.mint_agent_token(bp, "old-a")

    {1, _} =
      Repo.update_all(from(t in AgentToken, where: t.id == ^old_revoked.id),
        set: [revoked_at: days_ago(40)]
      )

    # Recently dead: revoked 5 days ago — still inside the 30-day grace.
    {:ok, _pt_b, recent_revoked} = Registry.mint_agent_token(bp, "recent-b")

    {1, _} =
      Repo.update_all(from(t in AgentToken, where: t.id == ^recent_revoked.id),
        set: [revoked_at: days_ago(5)]
      )

    assert {:ok, %{tokens_deleted: 1}} = perform_job(AgentRetentionWorker, %{})

    assert Repo.get(AgentToken, live.id)
    refute Repo.get(AgentToken, old_revoked.id)
    assert Repo.get(AgentToken, recent_revoked.id)
  end

  ## 4. agent_tokens — pruned by a long-past expires_at too.

  test "prunes agent_tokens 30+ days past expires_at" do
    team = team_fixture()
    bp = barkpark_fixture(team)

    {:ok, _pt, expired} = Registry.mint_agent_token(bp, "exp", expires_at: days_ago(45))
    {:ok, _pt2, live} = Registry.mint_agent_token(bp, "still-live")

    assert {:ok, %{tokens_deleted: 1}} = perform_job(AgentRetentionWorker, %{})

    refute Repo.get(AgentToken, expired.id)
    assert Repo.get(AgentToken, live.id)
  end

  ## 5. usage_samples — older than 14 days pruned, the window kept.

  # A cached usage sample, timestamped `days` old (measured_at is a plain field,
  # so we set the age directly at insert — no backdate needed).
  defp aged_sample(bp, days) do
    {:ok, s} =
      %Sample{}
      |> Sample.changeset(%{
        barkpark_id: bp.id,
        envelope: Usage.compose(%{}),
        measured_at: days_ago(days)
      })
      |> Repo.insert()

    s.id
  end

  test "prunes usage_samples older than 14 days and keeps the window" do
    team = team_fixture()
    bp = barkpark_fixture(team)

    old = aged_sample(bp, 20)
    keep_boundary = aged_sample(bp, 13)
    keep_fresh = aged_sample(bp, 1)

    assert {:ok, %{samples_deleted: 1}} = perform_job(AgentRetentionWorker, %{})

    refute Repo.get(Sample, old)
    assert Repo.get(Sample, keep_boundary)
    assert Repo.get(Sample, keep_fresh)
  end

  ## 5b. platform_deliveries — the platform's own delivery record, kept 180 days.

  # dr-w23-s2: one row per (sha, delivering run, first sighting). Backdated on
  # `inserted_at` — the recorder's clock, the only one on that table a caller
  # cannot supply, so a wrong `first_seen_at` can neither make a row immortal
  # nor delete it early.
  defp aged_delivery(days) do
    sha = String.downcase(Base.encode16(:crypto.strong_rand_bytes(20)))

    {:ok, %{recorded: 1}} =
      PlatformDelivery.record_all([
        %{
          "sha" => sha,
          "delivering_run_id" => "run-#{System.unique_integer([:positive])}",
          "first_seen_at" => DateTime.utc_now()
        }
      ])

    {1, _} =
      Repo.update_all(from(d in PlatformDelivery, where: d.sha == ^sha),
        set: [inserted_at: days_ago(days)]
      )

    sha
  end

  test "prunes platform_deliveries older than 180 days and keeps the window" do
    old = aged_delivery(200)
    keep_boundary = aged_delivery(179)
    keep_fresh = aged_delivery(1)

    assert {:ok, %{deliveries_deleted: 1}} = perform_job(AgentRetentionWorker, %{})

    assert {:ok, []} = PlatformDelivery.list(sha: old)
    assert {:ok, [_]} = PlatformDelivery.list(sha: keep_boundary)
    assert {:ok, [_]} = PlatformDelivery.list(sha: keep_fresh)
  end

  ## 5c. notification_deliveries — the alert/transactional delivery log, kept 180
  ##      days (cch-w34-bl-delivery-log-has-no-retention).
  ##
  ##      Nothing pruned this table at all: it was the last append-only table in
  ##      cloud/ with no retention arm. The window is 180 days, NOT the 14-day
  ##      sample window — this is evidence a person reads through
  ##      `GET /v1/notifications/deliveries`, which is the only surface that
  ##      answers "was I notified?".
  ##
  ##      MUTATION PROOF: delete the `prune_notification_deliveries/1` call from
  ##      `perform/1` (or point it at `@sample_retention_days`) and
  ##      "prunes notification_deliveries past 180 days ..." reds — the 200-day
  ##      row is still there, or the 179-day row is not.

  # Insert a delivery row for `team` (nil team_id is legal — identity emails
  # carry no team) and backdate its `inserted_at` to `days` old.
  defp aged_notification_delivery(team, days, attrs \\ %{}) do
    row =
      %Delivery{}
      |> Delivery.changeset(
        Enum.into(attrs, %{
          team_id: team && team.id,
          recipient: "u#{System.unique_integer([:positive])}@example.test",
          event: "deployment_failed",
          status: "sent"
        })
      )
      |> Repo.insert!()

    {1, _} =
      Repo.update_all(from(d in Delivery, where: d.id == ^row.id),
        set: [inserted_at: days_ago(days)]
      )

    row.id
  end

  test "prunes notification_deliveries past 180 days and keeps everything inside the window" do
    team = team_fixture()

    old = aged_notification_delivery(team, 200)
    keep_boundary = aged_notification_delivery(team, 179)
    keep_fresh = aged_notification_delivery(team, 1)

    assert {:ok, %{notification_deliveries_deleted: deleted}} =
             perform_job(AgentRetentionWorker, %{})

    assert deleted >= 1

    # The subject: THIS row, by id. Beyond the window it is gone; inside it, both
    # survive — including the one sitting one day short of the boundary.
    refute Repo.get(Delivery, old)
    assert Repo.get(Delivery, keep_boundary)
    assert Repo.get(Delivery, keep_fresh)
  end

  test "the prune is keyed on AGE alone, so one team's retention cannot reach another team's rows" do
    team_a = team_fixture()
    team_b = team_fixture()

    a_old = aged_notification_delivery(team_a, 400)
    a_keep = aged_notification_delivery(team_a, 10)
    b_keep = aged_notification_delivery(team_b, 10)
    b_keep_older = aged_notification_delivery(team_b, 179)
    # A user-scoped identity email carries no team at all; it is governed by the
    # same clock and nothing else.
    nil_team_keep = aged_notification_delivery(nil, 10)
    nil_team_old = aged_notification_delivery(nil, 400)

    assert {:ok, %{notification_deliveries_deleted: _}} =
             perform_job(AgentRetentionWorker, %{})

    # Team A had rows deleted in this very tick. Team B's rows are untouched —
    # and so is team A's own in-window row: the query carries no team parameter,
    # so a row lives or dies by its own age and by nothing a neighbour holds.
    refute Repo.get(Delivery, a_old)
    assert Repo.get(Delivery, a_keep)
    assert Repo.get(Delivery, b_keep)
    assert Repo.get(Delivery, b_keep_older)
    assert Repo.get(Delivery, nil_team_keep)
    refute Repo.get(Delivery, nil_team_old)
  end

  test "the bulk prune is BATCHED — a bounded tick cannot take more than limit x max_batches" do
    team = team_fixture()

    ids = for _ <- 1..5, do: aged_notification_delivery(team, 400)
    cutoff = days_ago(180)

    # limit 2, max_batches 2 → at most FOUR rows, in two statements. A single
    # unbounded `DELETE ... WHERE inserted_at < cutoff` would return 5 here (or
    # more, if the shared table held other rows); it cannot return 4.
    assert 4 == AgentRetentionWorker.prune_notification_deliveries(cutoff, 2, 2)

    survivors = Enum.count(ids, &Repo.get(Delivery, &1))
    assert survivors == 1

    # The next tick drains the remainder and then stops on the short batch.
    assert 1 == AgentRetentionWorker.prune_notification_deliveries(cutoff, 2, 2)
    assert Enum.all?(ids, &is_nil(Repo.get(Delivery, &1)))

    # And a cutoff with nothing behind it issues no DELETE at all.
    assert 0 == AgentRetentionWorker.prune_notification_deliveries(cutoff, 2, 2)
  end

  ## 6. Idempotency — a clean run is a no-op and never raises.

  test "perform is a no-op when nothing is old enough" do
    team = team_fixture()
    bp = barkpark_fixture(team)
    _fresh_event = aged_event(bp, 2)
    {:ok, _pt, _live} = Registry.mint_agent_token(bp, "report")

    assert {:ok, %{events_deleted: 0, tokens_deleted: 0, samples_deleted: 0}} =
             perform_job(AgentRetentionWorker, %{})
  end
end
