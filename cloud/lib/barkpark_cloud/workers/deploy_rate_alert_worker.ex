defmodule BarkparkCloud.Workers.DeployRateAlertWorker do
  @moduledoc """
  dr-bl-rate-notice — the hourly tick behind the deploy failure RATE notice.

  It owns no logic. It calls `Notifications.deliver_deploy_rate_notices/1` and
  logs the accounting that call returns; the reading, the verdict, the
  consecutive counter and the latch all live there and in
  `Notifications.DeployRateAlert`, next to the census they are taken from.

  ## Why hourly and not per deployment

  `deployment_failed` already fires per deployment — 840 emails in three days,
  three producers. Charter D14 forbids an 841st. This worker's cost is one
  census read per team per hour, and its OUTPUT ceiling is one email per team
  per red episode: the notice needs three consecutive red readings and then
  latches, so a fleet red for a whole day sends one email, not twenty-four.

  `27 * * * *` — off the hour, and off every other row in the crontab. The
  reading is a per-team `DeployLedger.census/3` scan (3.4ms scoped, measured in
  dr-w28-s5), so it is cheap; landing it on `0` would still put it on the same
  tick as `TrialExpiryWorker` for no reason.

  ## `max_attempts: 1`

  Same reasoning as `DailyDigestWorker` and `DeploymentAlertWorker`: the send
  has no per-recipient resume point, so a second attempt re-mails everyone the
  first attempt reached. A missed tick is harmless — the next hour reads a
  fresher window over the same rolling door, and the consecutive counter simply
  takes an hour longer to arm.

  ## `unique` over the PENDING states only

  The state list is spelled out rather than defaulted, for the reason
  `DailyDigestWorker`'s moduledoc records at length: Oban's default set includes
  `:completed`, which with `timestamp: :inserted_at` turns the period into a
  ROLLING window measured off the previous COMPLETED row — and cron jitter then
  silently drops ticks. Production lost 3 of 7 daily digests that way. A
  COMPLETED run from an hour ago must never suppress this one; only a run still
  in flight may.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [
      period: 3600,
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias BarkparkCloud.Notifications

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = Notifications.deliver_deploy_rate_notices()

    Logger.info(
      "deploy_rate_notice teams=#{result.teams} red=#{result.red} " <>
        "sent=#{result.sent} latched=#{result.latched}"
    )

    {:ok, result}
  end
end
