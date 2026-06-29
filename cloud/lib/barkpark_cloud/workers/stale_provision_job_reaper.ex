defmodule BarkparkCloud.Workers.StaleProvisionJobReaper do
  @moduledoc """
  oban-substrate sample worker — the cloud plane's first recurring job, and the
  concrete first win the scheduled-jobs gap analysis calls out.

  Today's provision-job staleness recovery is LAZY: a `claimed` job whose worker
  crashed (or whose succeed/fail report failed in transit) is only re-claimed or
  failed opportunistically on the NEXT `Registry.claim_next_job/1` call
  (cloud/lib/barkpark_cloud/registry.ex). If no new claims arrive, a wedged job
  sits in `claimed` indefinitely — the customer's barkpark stays "provisioning"
  forever. This is the cloud analog of the bug api/'s per-minute
  `Barkpark.Tasks.TtlSweeper` exists to kill.

  This worker runs every minute (the config.exs Cron entry) on the `:maintenance`
  queue and PROACTIVELY sweeps stale `claimed` jobs to a re-claimable / terminal
  state via `Registry.reap_stale_provision_jobs/0`. It reuses the SAME staleness
  threshold (`Registry.stale_after_seconds/0`) and attempt budget
  (`Registry.max_provision_attempts/0`) the lazy path uses, so the two recovery
  paths can never disagree.

  Idempotent: a sweep that finds nothing returns `{:ok, %{reaped: 0, failed: 0}}`
  and never raises. The `unique` window (60s) makes a slow sweep plus the next
  cron tick collapse to one in-flight job instead of stacking, and the per-row
  CAS inside the context fn means a race with the lazy path simply no-ops on the
  row the other path already moved.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, BarkparkCloud.Registry.reap_stale_provision_jobs()}
  end
end
