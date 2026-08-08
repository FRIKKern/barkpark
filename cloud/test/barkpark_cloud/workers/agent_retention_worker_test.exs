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
