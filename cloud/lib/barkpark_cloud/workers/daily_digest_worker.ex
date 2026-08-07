defmodule BarkparkCloud.Workers.DailyDigestWorker do
  @moduledoc """
  isu-w5 — the daily fleet-update digest send. Once a day (the `0 6 * * *`
  crontab entry) this reads the whole fleet and pushes a plain-text operator
  digest to the platform admins: where every managed instance stands against the
  newest release the fleet has seen. It turns the release curator's daily
  judgment from a draft Release + a run log (which a human must go look for) into
  something a human passively RECEIVES.

  It never computes a verdict and never calls GitHub — it reads only the update
  columns the fleet already polls (`Registry.all_barkparks/0`) and hands them to
  `Notifications.deliver_fleet_digest/1`, which resolves the operator recipients
  and renders/sends.

  Zero platform admins is NOT a no-op any more (dr-w18-s3). It is a COUNTED
  LOSS: `deliver_fleet_digest/1` emits `fleet_digest phase=settled recipients=0
  sent=0` at WARNING plus a `:telemetry` event, then returns `{:ok, :no_admins}`.
  This job still completes — a missing recipient list is not this job failing,
  and discarding it would only turn one unread Oban state into another (there is
  no Oban read route in the console at all) — so the accounting record, not the
  job state, is the thing that says the digest reached nobody.

  `unique: [period: 86_400]` guards against a double-enqueue landing two digests
  in the same day (the cron plugin fires once per tick, but a manual re-enqueue
  or a redeploy blip must not double-send). `max_attempts: 1` — a missed daily
  tick is harmless (the next day's digest is the same shape over fresher rows), so
  Oban should not retry-storm a transient blip. Crash-safe: one bad build can
  never wedge the queue.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1, unique: [period: 86_400]

  require Logger

  alias BarkparkCloud.{Notifications, Registry}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = Registry.all_barkparks() |> Notifications.deliver_fleet_digest()

    case result do
      # Deliberately silent HERE: `Notifications.deliver_fleet_digest/1` already
      # emitted the countable loss (warning + telemetry). A second line would be
      # a second vocabulary for the same event, which is how a reader ends up
      # trusting whichever one they grepped first.
      {:ok, :no_admins} ->
        :ok

      {:ok, %{sent: n}} ->
        Logger.info("DailyDigestWorker: fleet digest sent to #{n} platform admin(s)")
    end

    # Return the delivery result — both `{:ok, :no_admins}` and
    # `{:ok, %{sent, recipients}}` are valid Oban returns and keep the send
    # outcome observable (Oban.Testing, telemetry).
    result
  rescue
    e ->
      # A digest is best-effort operator convenience — one bad render/send must
      # never wedge the maintenance queue. Log and move on (next day retries).
      Logger.error("DailyDigestWorker crashed: #{Exception.message(e)}")
      :ok
  end
end
