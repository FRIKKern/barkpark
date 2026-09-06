defmodule BarkparkCloud.Workers.StaleWarmClaimReaperTest do
  @moduledoc """
  task-d5f8c2634f323169 — the warm-pool claim reaper had no clock.

  `Registry.reap_stale_warm_claims/0` is the ONLY recovery for a leaked
  `warm_servers` claim, and before this worker its only two production call sites
  were inside the two claim transactions. Recovery was therefore LAZY: it ran only
  when a NEW claim arrived, and the provisioner defaults `WARM_POOL_SIZE` to 0, so
  "no new claim ever arrives" is the default rather than an edge. A leaked
  `claimed`/`retiring` row is a real billed Hetzner box nothing tracks.

  Four tests, in the order the row's criteria ask for them:

    1. THE GAP (C1) — time alone reclaims nothing. Leak a claim, age it far past
       `warm_stale_after_seconds`, run no new claim and no worker: the row is still
       there. This test passes on origin/main AND after this change; it pins that
       the fix is a DRIVER, not a change to the reap.
    2. THE DRIVER (C0) — the same leaked row, with `perform_job/2` on this worker
       as the only thing that runs, is gone.
    3. SAFETY (C2) — a claim NEWER than the stale window survives the scheduled
       run untouched, claim_token intact: a live provisioner is never raced.
    4. WIRING — a crontab row schedules this worker every minute on `:maintenance`,
       read off the configured Oban plugins (not off config.exs as text).

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs);
  `perform_job/2` runs the worker synchronously in this test's own transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.WarmServer
  alias BarkparkCloud.Workers.StaleWarmClaimReaper

  # Register a warm box, claim it, then advance its claim_at INTO the past by
  # more than the stale window — the "worker crashed between claim and consume"
  # leak, with the clock moved rather than the test sleeping.
  defp leak_claim(name) do
    {:ok, _} = Registry.register_warm_server(name, "10.0.0.9")
    %WarmServer{claim_token: "tok-crashed"} = Registry.claim_warm_server("tok-crashed")

    stale_at =
      DateTime.utc_now()
      |> DateTime.add(-(Registry.warm_stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      from(w in WarmServer, where: w.name == ^name)
      |> Repo.update_all(set: [claimed_at: stale_at])

    :ok
  end

  defp row(name), do: Repo.get_by(WarmServer, name: name)

  ## 1. C1 — THE GAP. No new claim, no scheduled worker: the leaked row survives.

  test "a leaked claim aged past the stale window survives when NOTHING drives the reap" do
    :ok = leak_claim("warm-leak-gap")

    # The clock is already past the threshold — the ONLY missing ingredient is a
    # driver. Nothing is called here: no claim, no reap, no worker.
    assert %WarmServer{status: "claimed", claim_token: "tok-crashed"} = row("warm-leak-gap")

    # And it stays that way however far past the window the clock is pushed: the
    # lazy path is reached only from inside a claim transaction.
    {1, _} =
      from(w in WarmServer, where: w.name == "warm-leak-gap")
      |> Repo.update_all(
        set: [
          claimed_at:
            DateTime.utc_now()
            |> DateTime.add(-(Registry.warm_stale_after_seconds() * 100), :second)
            |> DateTime.truncate(:microsecond)
        ]
      )

    assert %WarmServer{status: "claimed"} = row("warm-leak-gap")
  end

  ## 2. C0 — THE DRIVER. The scheduled worker alone reclaims the same row.

  test "the scheduled worker reclaims the leaked row with no new claim arriving" do
    :ok = leak_claim("warm-leak-reaped")
    assert %WarmServer{status: "claimed"} = row("warm-leak-reaped")

    assert {:ok, %{reaped: 1}} = perform_job(StaleWarmClaimReaper, %{})

    # claimed/retiring are DELETED (the Go worker owns the box's lifecycle).
    refute row("warm-leak-reaped")
  end

  test "the scheduled worker returns a stale refreshing box to the assignable pool" do
    {:ok, _} = Registry.register_warm_server("warm-leak-refresh", "10.0.0.8")
    %WarmServer{} = Registry.claim_warm_server_for_refresh("tok-refresh", 0)

    stale_at =
      DateTime.utc_now()
      |> DateTime.add(-(Registry.warm_stale_after_seconds() + 60), :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      from(w in WarmServer, where: w.name == "warm-leak-refresh")
      |> Repo.update_all(set: [claimed_at: stale_at])

    assert {:ok, %{reaped: 1}} = perform_job(StaleWarmClaimReaper, %{})

    assert %WarmServer{status: "ready", claim_token: nil, claimed_at: nil} =
             row("warm-leak-refresh")
  end

  ## 3. C2 — SAFETY. A claim inside the window is untouched by the scheduled run.

  test "a claim NEWER than the stale window is untouched by the scheduled run" do
    {:ok, _} = Registry.register_warm_server("warm-live-claim", "10.0.0.7")
    %WarmServer{claim_token: "tok-live"} = Registry.claim_warm_server("tok-live")

    # Deliberately INSIDE the window: aged, but not stale.
    fresh_at =
      DateTime.utc_now()
      |> DateTime.add(-div(Registry.warm_stale_after_seconds(), 2), :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      from(w in WarmServer, where: w.name == "warm-live-claim")
      |> Repo.update_all(set: [claimed_at: fresh_at])

    assert {:ok, %{reaped: 0}} = perform_job(StaleWarmClaimReaper, %{})

    assert %WarmServer{status: "claimed", claim_token: "tok-live"} = row("warm-live-claim")
  end

  test "a ready box is never touched, and a leaked row beside it still goes" do
    # ORDER MATTERS: claim_warm_server/1 takes the OLDEST ready box, so the leak
    # is staged FIRST and the bystander registered after it.
    :ok = leak_claim("warm-leak-beside")
    {:ok, _} = Registry.register_warm_server("warm-untouched-ready", "10.0.0.6")

    assert {:ok, %{reaped: 1}} = perform_job(StaleWarmClaimReaper, %{})

    assert %WarmServer{status: "ready", claimed_at: nil} = row("warm-untouched-ready")
    refute row("warm-leak-beside")
  end

  ## 4. WIRING — the crontab row, read off the configured Oban plugins.

  test "the reaper is scheduled every minute on the maintenance queue" do
    crontab =
      Application.fetch_env!(:barkpark_cloud, Oban)[:plugins]
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, opts} -> opts[:crontab]
        _ -> nil
      end)

    assert {"* * * * *", StaleWarmClaimReaper} in crontab

    assert Ecto.Changeset.get_field(StaleWarmClaimReaper.new(%{}), :queue) == "maintenance"
  end
end
