defmodule BarkparkCloud.Workers.StaleWarmClaimReaperTest do
  @moduledoc """
  The warm-pool claim reaper's SCHEDULED driver (task-d5f8c2634f323169).

  `Registry.reap_stale_warm_claims/0` was already correct and already tested
  (cloud/test/barkpark_cloud/warm_pool_test.exs) — what was missing was anything
  that CALLS it without a new claim arriving. Its only two production call sites
  were both inside a claim transaction (`claim_warm_server/1`,
  `claim_warm_server_for_refresh/2`), so a leaked `claimed`/`retiring` row — a
  real, billed Hetzner box — sat forever whenever no new claim arrived, which is
  the normal state of the world: `WARM_POOL_SIZE` defaults to 0 in
  cmd/barkpark-provisioner/main.go, so the pool (and therefore every claim path)
  is OFF unless an operator opts in.

  Every test here is scoped to the warm rows its own fixture created — the test
  database is shared with other agents, so nothing may assert over the whole
  table.

  Clock advancement is done by SETTING `claimed_at` directly. Never
  `Process.sleep` — the stale window is twelve minutes.

  `async: true` is safe because Oban runs in `:manual` mode (config/test.exs) —
  no background poller touches the sandboxed connection; `perform_job/2` runs the
  worker synchronously inside this test's own transaction.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.WarmServer
  alias BarkparkCloud.Workers.StaleWarmClaimReaper

  ## Fixtures — every name is unique so each test only ever sees its own rows.

  defp warm_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp register(name), do: {:ok, _} = Registry.register_warm_server(name, "10.0.0.1")

  # Set claimed_at directly — the ONLY way this suite advances the clock.
  defp set_claimed_at(name, seconds_ago) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> DateTime.truncate(:microsecond)

    {1, _} =
      from(w in WarmServer, where: w.name == ^name) |> Repo.update_all(set: [claimed_at: at])

    :ok
  end

  defp stale_seconds, do: Registry.warm_stale_after_seconds() + 60

  defp row(name), do: Repo.get_by(WarmServer, name: name)

  # Claim a freshly-registered box. `claim_warm_server/1` takes the OLDEST READY
  # row, so this is only unambiguous while the box just registered is the only
  # ready one — every caller below keeps it that way.
  defp register_and_claim(name) do
    register(name)
    %WarmServer{} = ws = Registry.claim_warm_server("ct-#{name}")
    assert ws.name == name
    name
  end

  # Leak a claim: claim the box, then backdate the claim past the stale window,
  # exactly as a worker that crashed between claiming and consuming the row does.
  #
  # NOTE the ordering rule this helper obeys and every multi-box test below must
  # too: BOTH warm claim paths run `reap_stale_warm_claims_txn/1` inside their own
  # transaction (that is the lazy recovery this worker exists to replace), so a
  # claim issued AFTER a backdate would reap the leak before the scheduled worker
  # ever sees it. Do all claiming first, all backdating last.
  defp leak_claim(name) do
    register_and_claim(name)
    set_claimed_at(name, stale_seconds())
    name
  end

  ## 1. Cron wiring — the scheduled driver exists at all (criterion 0).

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

  ## 2. The gap (criterion 1) and its fix (criterion 0), in one story.

  test "a leaked claim survives with no new claim and no scheduled run, then the scheduled run reclaims it" do
    name = leak_claim(warm_name("warm-leak"))

    # THE GAP — this is the pre-fix world: the pool is disabled / the provisioner
    # is down, so no new claim arrives and the in-claim reaper never fires. The
    # leaked row (a billed box) is still sitting there.
    assert %WarmServer{status: "claimed"} = row(name)

    # THE FIX — the scheduled driver runs on its own, with no claim in sight.
    assert {:ok, %{recovered: 1}} = perform_job(StaleWarmClaimReaper, %{})

    assert row(name) == nil
  end

  test "a leaked retiring row is reclaimed by the scheduled run" do
    name = warm_name("warm-retire")
    register(name)
    assert %WarmServer{status: "retiring"} = Registry.claim_warm_server_for_retire("rt-#{name}")
    set_claimed_at(name, stale_seconds())

    assert %WarmServer{status: "retiring"} = row(name)
    assert {:ok, %{recovered: 1}} = perform_job(StaleWarmClaimReaper, %{})
    assert row(name) == nil
  end

  test "a leaked refreshing row is returned to the pool (ready), not deleted, by the scheduled run" do
    name = warm_name("warm-refresh")
    register(name)
    assert %WarmServer{name: ^name} = Registry.claim_warm_server_for_refresh("rf-#{name}", 0)
    set_claimed_at(name, stale_seconds())

    assert %WarmServer{status: "refreshing"} = row(name)
    assert {:ok, %{recovered: 1}} = perform_job(StaleWarmClaimReaper, %{})

    recovered = row(name)
    assert recovered.status == "ready"
    assert is_nil(recovered.claim_token)
    assert is_nil(recovered.claimed_at)
  end

  ## 3. Safety under a live provisioner (criterion 2) — the outage guard.

  test "a claim NEWER than the stale window is untouched by the scheduled run" do
    live = register_and_claim(warm_name("warm-live"))

    # One second short of the threshold: a still-running assign chain.
    set_claimed_at(live, Registry.warm_stale_after_seconds() - 1)

    assert {:ok, %{recovered: 0}} = perform_job(StaleWarmClaimReaper, %{})

    untouched = row(live)
    assert untouched.status == "claimed"
    assert untouched.claim_token == "ct-#{live}"
  end

  test "the scheduled run spares a live claim while reaping a leaked one in the same sweep" do
    # All claiming first (each claim would otherwise lazily reap the leak), all
    # backdating after.
    leaked = register_and_claim(warm_name("warm-leaked"))
    live = register_and_claim(warm_name("warm-live"))

    # A refreshing box that is also still live must survive as refreshing.
    fresh_refresh = warm_name("warm-refreshing-live")
    register(fresh_refresh)

    assert %WarmServer{name: ^fresh_refresh} =
             Registry.claim_warm_server_for_refresh("rf-#{fresh_refresh}", 0)

    set_claimed_at(leaked, stale_seconds())
    set_claimed_at(live, Registry.warm_stale_after_seconds() - 1)
    set_claimed_at(fresh_refresh, Registry.warm_stale_after_seconds() - 1)

    assert {:ok, %{recovered: 1}} = perform_job(StaleWarmClaimReaper, %{})

    assert row(leaked) == nil
    assert row(live).status == "claimed"
    assert row(fresh_refresh).status == "refreshing"
  end

  ## 4. Idempotency — a sweep that finds nothing is a no-op and never raises.

  test "a second sweep over the same rows recovers nothing and leaves ready boxes alone" do
    # Leak FIRST: a later claim would lazily reap it, and a later register is
    # harmless (register does not reap).
    leaked = leak_claim(warm_name("warm-idem"))
    ready = warm_name("warm-ready")
    register(ready)

    assert {:ok, %{recovered: 1}} = perform_job(StaleWarmClaimReaper, %{})
    assert {:ok, %{recovered: 0}} = perform_job(StaleWarmClaimReaper, %{})

    assert row(leaked) == nil
    assert row(ready).status == "ready"
  end
end
