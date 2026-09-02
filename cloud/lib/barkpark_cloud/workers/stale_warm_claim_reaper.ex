defmodule BarkparkCloud.Workers.StaleWarmClaimReaper do
  @moduledoc """
  The warm-pool twin of `StaleProvisionJobReaper` / `StaleDeploymentReaper` — the
  third of the three claim tables, and the only one that never got a scheduled
  sweep.

  `Registry.reap_stale_warm_claims/0` is correct and is the ONLY thing that
  recovers a leaked `warm_servers` claim, but until this worker existed its only
  two production call sites were both INSIDE a claim transaction
  (`claim_warm_server/1` and `claim_warm_server_for_refresh/2` in
  cloud/lib/barkpark_cloud/registry.ex). So recovery was LAZY: it ran only when a
  NEW claim arrived — exactly the disease `StaleProvisionJobReaper`'s moduledoc
  was written to kill.

  Lazy is worse here than for provision jobs, because the trigger is OFF BY
  DEFAULT: `cmd/barkpark-provisioner/main.go` defaults `WARM_POOL_SIZE` to 0 (the
  pool DISABLED) and gates the warm client, reconciler and refresher on
  `poolSize > 0`. Whenever the pool is disabled, the provisioner is stopped,
  crashed or mid-deploy, NOTHING claims a warm box and therefore NOTHING ever
  reaps — precisely when a leak is most likely. That is why this worker is
  UNCONDITIONAL: it is not gated on pool size or on the provisioner being alive,
  because "the provisioner is not running" is the failure it exists to survive.
  With the pool disabled the sweep simply matches zero rows.

  What a leak costs: each stranded `claimed`/`retiring` row is a real Hetzner box
  the control plane no longer tracks and no reconciler will ever see — billed
  until a human notices. It also hides its own symptom, because
  `count_ready_warm_servers/0` counts only `ready` + `refreshing`, so a leaked
  row shrinks the pool's apparent size without triggering a refill. A leaked
  `refreshing` row is a healthy pool box removed from the assignable set forever.

  Blast radius, and the reason a reaper is safe to schedule at all: the sweep
  reuses the SAME `Registry.warm_stale_after_seconds/0` threshold the lazy path
  uses (12 minutes by default — the Go worker's 8-minute provision timeout plus
  margin for the assign chain), so the scheduled path and the in-claim path can
  never disagree, and a claim NEWER than that window is untouched. A reaper that
  ate live claims would be far worse than the leak it fixes: the `claimed_at <
  stale_before` predicate inside `reap_stale_warm_claims/0` is what spares a
  running assign.

  Idempotent: a sweep that finds nothing returns `{:ok, %{recovered: 0}}` and
  never raises. The `unique` window (60s) collapses a slow sweep plus the next
  cron tick into one in-flight job instead of stacking, and the status-guarded
  passes inside the context transaction simply no-op on a row a concurrent claim
  already moved.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    # Collapse a slow sweep + the next cron tick to one in-flight job. The unique
    # window must span ALL incomplete states (`:available`, `:scheduled`,
    # `:executing`, `:retryable`, `:suspended`) or Oban warns that a job parked in
    # an omitted state would slip the guard and let a duplicate enqueue.
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    recovered = BarkparkCloud.Registry.reap_stale_warm_claims()

    if recovered > 0 do
      Logger.info(
        "stale_warm_claim_reaper: recovered #{recovered} stale warm claim(s) " <>
          "(stale_after=#{BarkparkCloud.Registry.warm_stale_after_seconds()}s)"
      )
    end

    {:ok, %{recovered: recovered}}
  end
end
