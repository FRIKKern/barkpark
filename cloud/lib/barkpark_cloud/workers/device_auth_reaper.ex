defmodule BarkparkCloud.Workers.DeviceAuthReaper do
  @moduledoc """
  Per-minute hygiene sweep of expired device-authorization requests (bp-login-ux),
  the twin of `StaleProvisionJobReaper` on the `:maintenance` queue.

  Expiry is already enforced IN-BAND: every `BarkparkCloud.DeviceAuth` query
  filters `expires_at > now`, so a request past its 600s TTL is dead to poll /
  inspect / approve the instant it lapses — the CLI can never mint from it and no
  browser can approve it. This worker is pure hygiene: it DELETES the lapsed rows
  (abandoned flows the user never completed) so `device_auth_requests` doesn't
  accumulate tombstones. Correctness never depends on it running.

  Idempotent: a sweep that finds nothing returns `{:ok, %{reaped: 0}}` and never
  raises. The `unique` window (60s) collapses a slow sweep plus the next cron tick
  to one in-flight job instead of stacking.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, BarkparkCloud.DeviceAuth.reap_expired()}
  end
end
