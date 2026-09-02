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
  `{:ok, :no_admins}` (the atom is kept verbatim — it is the delivery function's
  own contract and three test files pin it).

  AND THIS JOB REFUSES IT (dr-w26 escalation). It used to return that tuple
  straight through, so Oban wrote `state = "completed"` over a run that mailed
  nobody: every Oban read — `SELECT state FROM oban_jobs`, a future dashboard,
  the operator's eye — reported a healthy daily digest for the entire life of the
  channel. dr-w18-s3 argued the accounting record was enough and that "discarding
  it would only turn one unread Oban state into another". The 2026-08-08 outage
  refuted the first half: a WARNING line in journald is only loud to somebody
  already tailing journald, and nobody was. The second half is answered by
  reading the states rather than the docs — `completed` and `cancelled` are not
  two equally-unread words. `completed` is the word every "is it working?" query
  filters FOR, so recording it is an ACTIVE FALSE CLAIM; `cancelled` is a state
  Oban carries a REASON on (`oban_jobs.errors`), and `{:cancel, reason}` is the
  only return that puts this branch's own word there.

  `{:cancel, :no_team_recipients}` and NOT `{:error, …}`: an error is a RETRY
  instruction, and the audience does not change between attempts — an empty
  membership table is empty on attempt two. `:cancel` is terminal on the first
  attempt by construction, so the loudness costs no retry storm (and with
  `max_attempts: 1` below an error would land in `discarded`, which reads as a
  crash rather than as a refusal, and carries a formatted exception where the
  reason belongs).

  WHAT THIS DOES NOT DO, said out loud: it does not invent a recipient, it does
  not blast the fleet's state to every team (charter D362 — the digest is
  per-team and its body names instances), and it does not make anything ARRIVE.
  A cancelled row is a record a human can find; it is not a push. The audience
  itself remains a human gate: `PLATFORM_ADMIN_EMAILS` is unset on prod and
  settable by no route, console action or User field
  (`dr-bl-w5-census-is-dark-to-every-human`), so there is no platform address to
  send to and this slice deliberately does not manufacture one.

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

  ## "FOUR TIMES IN ITS LIFE" — the cadence, accounted to the row (dr-w26)

  Charter D456 reports that this worker "has completed FOUR times in its life
  (08-02, 08-04, 08-05, 08-07) and did not run on the outage day". Both halves of
  that sentence have an answer and they are different answers.

  THE WORD "LIFE" IS NOT MEASURABLE OFF `oban_jobs`. `Oban.Plugins.Pruner` runs
  with `max_age: 60 * 60 * 24 * 7` (`config/config.exs`, beside the crontab), and
  it reaps `completed` / `cancelled` / `discarded` rows. A daily worker can
  therefore never show more than SEVEN rows however long it has run, and a
  lifetime count taken from that table is a seven-day count wearing the wrong
  name. Read back with that bound, D456's own dates close exactly: the retained
  window ending on the outage day is 08-02 … 08-08, seven days, of which FOUR
  carry a digest row (08-02, 08-04, 08-05, 08-07) and THREE do not (08-03, 08-06,
  08-08). 4 + 3 = 7, with no unexplained remainder.

  AND THE THREE MISSING DAYS ARE THE ROLLING-WINDOW DEFECT ABOVE, by name —
  dr-w29-s4 measured the same three dates (08-03, 08-06, 08-08) from the other
  end. So the two facts are one fact: the digest was not running four times a
  lifetime, it was running four days out of the last seven, and the state list
  named above is why the other three vanished without a row, a log or a
  telemetry event.

  ONE RESIDUAL, NAMED AND NOT FIXED HERE. `Oban.Plugins.Cron` (OSS) enqueues only
  on a tick a running node observes; it does not backfill a tick nobody was up
  for. A blue/green container replacement crossing 06:00Z therefore still costs a
  day silently — the same mechanism D456 records eating a `UsageSamplerWorker`
  tick at the ~23:51Z cutover on the outage night. Closing THAT needs either a
  guaranteed-cron engine or a second scheduled job whose whole purpose is to
  notice a missing first one, and a new scheduled alert producer is a charter D14
  question, not a builder's.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 86_400, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  require Logger

  alias BarkparkCloud.{Notifications, Registry}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Registry.all_barkparks() |> Notifications.deliver_fleet_digest() do
      # THE REFUSAL, IN THE ONE PLACE OBAN READS. No second log line here:
      # `deliver_fleet_digest/1` already emitted the countable loss (warning +
      # telemetry) and a second vocabulary for the same event is how a reader
      # ends up trusting whichever one they grepped first. What this arm adds is
      # the JOB STATE — `cancelled` carrying `:no_team_recipients`, instead of
      # `completed` carrying nothing. See the moduledoc for why cancel, not error.
      {:ok, :no_admins} ->
        {:cancel, :no_team_recipients}

      # The send outcome stays observable (Oban.Testing, telemetry) — the tuple
      # is returned verbatim rather than collapsed to `:ok`.
      {:ok, %{sent: n}} = result ->
        Logger.info("DailyDigestWorker: fleet digest sent to #{n} team member(s)")
        result
    end
  rescue
    e ->
      # A digest is best-effort operator convenience — one bad render/send must
      # never wedge the maintenance queue. Log and move on (next day retries).
      Logger.error("DailyDigestWorker crashed: #{Exception.message(e)}")
      :ok
  end
end
