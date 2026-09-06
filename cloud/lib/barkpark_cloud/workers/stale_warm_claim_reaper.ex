defmodule BarkparkCloud.Workers.StaleWarmClaimReaper do
  @moduledoc """
  The warm-pool twin of `StaleProvisionJobReaper` — the third and last of the
  three claim tables to get a scheduled driver.

  `Registry.reap_stale_warm_claims/0` is correct and it is the ONLY thing that
  recovers a leaked `warm_servers` claim: it DELETES stale `claimed`/`retiring`
  rows (bookkeeping — the Go worker owns the box) and returns stale `refreshing`
  rows to `ready`. Before this worker it had no cron entry, and its only two
  production call sites were INSIDE the two claim transactions
  (`Registry.claim_warm_server/1` and `Registry.claim_warm_server_for_refresh/2`),
  so recovery was LAZY in exactly the sense `StaleProvisionJobReaper`'s moduledoc
  was written to kill: with no new claim arriving, a leaked row sat forever.

  That "no new claim arrives" case is the DEFAULT, not an edge: the provisioner
  gates its warm client, reconcile and refresh loops on `WARM_POOL_SIZE > 0`, and
  the default is 0. So whenever the pool is disabled, the provisioner is stopped,
  crashed, or mid-deploy, nothing claimed and therefore nothing reaped — while a
  leaked `claimed`/`retiring` row is a real, billed Hetzner box the control plane
  no longer tracks, and a leaked `refreshing` row is a pool member removed from
  the assignable set indefinitely. `Registry.count_ready_warm_servers/0` counts
  only `ready` + `refreshing`, so a leaked row also shrinks the pool's apparent
  size without triggering a refill — it hides its own symptom.

  This worker changes NO semantics. It reuses the same `Registry.reap_stale_warm_claims/0`
  and therefore the same `Registry.warm_stale_after_seconds/0` threshold the lazy
  path uses, so the two recovery paths can never disagree; all it adds is a clock.

  Idempotent: a sweep that finds nothing returns `{:ok, %{reaped: 0}}` and never
  raises. The `unique` window (60s) collapses a slow sweep plus the next cron tick
  into one in-flight job, and the reap runs in its own transaction, so a race with
  the lazy path simply finds the row the other path already moved.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Must span ALL incomplete states or Oban warns that a job parked in an
    # omitted state slips the guard (the StaleProvisionJobReaper precedent).
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, %{reaped: BarkparkCloud.Registry.reap_stale_warm_claims()}}
  end
end
