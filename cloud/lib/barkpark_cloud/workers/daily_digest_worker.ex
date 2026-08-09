defmodule BarkparkCloud.Workers.DailyDigestWorker do
  @moduledoc """
  isu-w5 — the daily fleet-update digest send. Once a day (the `0 6 * * *`
  crontab entry) this reads the whole fleet and pushes a plain-text digest:
  where every managed instance stands against the newest release the fleet has
  seen. It turns the release curator's daily judgment from a draft Release + a
  run log (which a human must go look for) into something a human passively
  RECEIVES.

  It never computes a verdict and never calls GitHub — it reads only the update
  columns the fleet already polls (`Registry.all_barkparks/0`) and hands them to
  `Notifications.deliver_fleet_digest/1`, which partitions the fleet BY TEAM,
  resolves each team's own members as the recipients (dr-w19-s5 — it used to
  resolve the platform-admin allowlist, which is unset on prod and joinable by
  nobody), and renders/sends.

  A fleet with no team that has a member is NOT a no-op (dr-w18-s3). It is a
  COUNTED LOSS: `deliver_fleet_digest/1` emits `fleet_digest phase=settled
  recipients=0 sent=0` at WARNING plus a `:telemetry` event, then returns
  `{:ok, :no_admins}` (the atom is kept verbatim — it is this function's match).
  This job still completes — a missing recipient list is not this job failing,
  and discarding it would only turn one unread Oban state into another (there is
  no Oban read route in the console at all) — so the accounting record, not the
  job state, is the thing that says the digest reached nobody.

  `unique:` collapses a digest that is still PENDING — `[:available,
  :scheduled, :executing, :retryable, :suspended]`, the same state set every
  other worker in this directory names — so a manual re-enqueue or a redeploy
  blip cannot land two digests at once. The state list is spelled out on purpose
  (dr-w29-s4): Oban's default set INCLUDES `:completed`, and with
  `timestamp: :inserted_at` that turns the period into a ROLLING 86,400s window
  measured off YESTERDAY'S completed row rather than a calendar day. Cron tick
  jitter is sub-second, so any tick landing microseconds earlier in the second
  than the previous one was refused as a duplicate — no Oban row, no log, no
  telemetry, no delivery record. Production lost 3 of 7 days that way (08-03,
  08-06, 08-08 have no digest job at all). A COMPLETED digest from yesterday
  must never suppress today's; only a digest still in flight may.

  `max_attempts: 1` — a missed daily tick is harmless (the next day's digest is
  the same shape over fresher rows), so Oban should not retry-storm a transient
  blip. Crash-safe: one bad build can never wedge the queue.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 86_400, states: [:available, :scheduled, :executing, :retryable, :suspended]]

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
        Logger.info("DailyDigestWorker: fleet digest sent to #{n} team member(s)")
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
