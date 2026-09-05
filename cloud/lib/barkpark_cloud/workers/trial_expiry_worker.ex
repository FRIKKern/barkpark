defmodule BarkparkCloud.Workers.TrialExpiryWorker do
  @moduledoc """
  dwb-13 — the free-trial lifecycle worker. Runs hourly on the `:maintenance`
  queue and, over every ACTIONABLE `trial` subscription (`Billing.active_trials/1`
  — live, with a window closing inside the scan horizon):

    1. **Advance notices.** Sends a T-3-day and a T-1-day heads-up via the
       notifications system (`:trial_expiring`). Each threshold is claimed with
       an atomic `UPDATE … WHERE <stamp> IS NULL` on the team ledger, so an
       hourly cadence sends each notice EXACTLY ONCE — no spam. A team that has
       muted alerts entirely (`alerts_enabled: false`) claims NOTHING: the stamp
       is a one-shot budget with no reader and no second chance, so spending it
       on a notice that was never sent would silently cost the team its warning
       (cch-w52-s2).

    2. **Expiry teardown.** For a trial whose window has closed
       (`current_period_end <= now`) and that did NOT convert, enqueues a
       DEPROVISION job for each of the team's boxes through the EXISTING
       deprovision path (`Registry.enqueue_deprovision_job/1`) — no parallel
       teardown machinery. Idempotent: a still-pending teardown is deduped
       (`:already_deprovisioning`).

       AND IT NOTIFIES (cch-w52-bl). Until this slice the teardown was the one
       destructive act in the lifecycle that dispatched nothing: the T-3 and T-1
       advance notices were the ONLY warning a team ever got, and a team that
       missed both learned its instances were gone at the outage. Measured on a
       trial whose window was already closed: `%{expired: 1, teardowns: 1}`,
       `delivery_rows_any_status = 0`, one `{"deprovision","pending"}` job and no
       notification of any kind. The teardown arm now dispatches `:trial_expired`
       — a NEW event, not a day-0 reuse of `trial_expiring`, because "we have
       torn your instances down" is a different fact from "your trial is ending"
       and future-tense copy about a past event is the lie this wave deletes.

       THE PASS THAT TORE DOWN IS THE PASS THAT TELLS. The notice is gated on
       THIS pass having actually won the enqueue for at least one box, which
       makes it exactly-once by riding the dedup that already exists rather than
       inventing a second budget: a still-pending teardown returns
       `:already_deprovisioning` on every later pass, a SUCCEEDED one deletes the
       barkpark row so there is nothing left to enqueue, and a finalised trial
       has left `Billing.active_trials/1` for good. It is also the only moment
       the instance NAMES exist — `Registry.succeed_deprovision_job/1` deletes
       the row — and the mail names them.

       THE LIMIT, STATED SO NOBODY OVER-READS IT: a lapsed trial with NO boxes
       gets no `trial_expired` notice, because this worker tore nothing down. The
       fifteen ghost rows of cch-w50 carry exactly that shape. A notice there
       would be a teardown report about a teardown this pass did not perform, and
       it could name nothing.

    3. **Finalisation (cch-w50).** Once the teardown has actually HAPPENED — the
       team has no boxes left — writes the terminal status on the subscription
       row (`Billing.expire_trial/2` → `canceled`). Until cch-w50 this step did
       not exist: the worker wrote NOTHING to `subscriptions`, so a lapsed trial
       kept `plan "trial" / status "active"` forever, `active_trials/0` re-read
       it hourly forever, and the console — which routes on the row, not on the
       clock — kept serving the running-trial card to a team whose box was
       already gone. Fifteen such rows were live on 2026-08-07, the oldest three
       weeks old.

       THE ORDER IS LOAD-BEARING. Finalising is gated on the boxes being GONE,
       not on the teardown being ENQUEUED, and that gate is what keeps the
       convert-just-after-expiry race closed: while a box still exists the row
       stays `trial`/`active`, so a checkout landing in that window still takes
       `activate_from_session/4`'s in-place trial arm — the one that cancels the
       pending deprovision. A team with no boxes at all is finalised on the first
       pass, which is exactly the shape all fifteen ghosts carry.

  MONEY-PATH SAFETY (adversarial): a CONVERTED team's live row is a PAID plan, so
  `active_trials/1` never returns it — this worker only ever sees `plan ==
  "trial"` rows and thus can NEVER tear down a subscribed team's box or spam it
  with expiry notices. The trial→paid conversion additionally cancels any
  in-flight teardown (`Registry.cancel_pending_deprovision_jobs/1`), closing the
  convert-just-after-expiry race.

  Idempotent + never raises: a run over nothing due returns zero counts. The
  `unique` window collapses a slow run + the next tick to one in-flight job.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 600, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  import Ecto.Query, warn: false

  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.{Billing, Notifications, Registry, Repo}

  # Advance-notice thresholds, in seconds. A trial with `remaining <= @one_day`
  # gets the T-1 notice; `@one_day < remaining <= @three_days` gets the T-3 one.
  #
  # These stay module attributes because the two `maybe_notice/5` guards need a
  # compile-time literal. Everything else — the accessor, the call sites, the
  # console mirror — reads them THROUGH `@notice_thresholds` below.
  @one_day 86_400
  @three_days 3 * 86_400

  # cch-w50-s5 — THE SCHEDULE, NAMED ONCE. Until this slice the day count in the
  # notice was a bare literal at the call site (`notify(team, sub, 3)`),
  # structurally decoupled from the threshold that selected the recipient. Both
  # renderers derive the whole sentence from that integer
  # (`Notifications.Render.trial_window/1`, `EventEmail.trial_window/1`), so THE
  # INTEGER IS THE SENTENCE: nothing anywhere connected "who we told" to "what we
  # told them". Measured on origin/main — widening `@three_days` and
  # `Billing.@trial_scan_horizon_seconds` to five days left the committed suite
  # fully GREEN (37 tests, 0 failures) while a trial ending in FOUR days was
  # noticed with `days: 3` and a body reading "Your free trial ends in 3 days."
  @notice_thresholds [three_day: @three_days, one_day: @one_day]

  @doc """
  The advance-notice schedule in WHOLE DAYS, longest first — `[3, 1]`.

  PUBLIC on purpose. This is the one statement of the schedule the rest of the
  system is allowed to read: `notify/3`'s day count is derived from it (so the
  number a team is told can never drift from the threshold that selected them),
  and `cloud/test/barkpark_cloud/billing_client_mirror_test.exs` compares it to
  the console's `TRIAL_NOTICE_DAYS` — the client half of the same promise, which
  the billing screen renders as "We'll remind you 3 days and 1 day before the
  trial ends." Before this accessor existed both attributes were private with no
  reader outside this file, and that sentence was a hand-typed re-statement no
  test connected to anything.

  REACHABILITY, and it is NOT this module's to enforce. A threshold beyond
  `Billing.trial_scan_horizon_seconds/0` is DEAD — `Billing.active_trials/1`
  never returns a row that far out, so the arm cannot fire. That coherence is
  asserted in `trial_expiry_worker_test.exs` rather than here, because the two
  values belong to different modules and a runtime check in this worker would
  raise inside an hourly cron rather than in CI.
  """
  @spec notice_thresholds_days() :: [pos_integer(), ...]
  def notice_thresholds_days do
    Enum.map(@notice_thresholds, fn {_key, seconds} -> div(seconds, 86_400) end)
  end

  # The day count for ONE threshold, derived from the same keyword list the
  # accessor publishes. This is what makes the call sites literal-free.
  defp notice_days(key), do: div(Keyword.fetch!(@notice_thresholds, key), 86_400)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, run(DateTime.utc_now())}
  end

  @doc """
  Scan the live trials once against `now`. Returns a summary map
  `%{noticed_3d, noticed_1d, expired, teardowns, finalized}`. Public so tests can
  drive it deterministically (the `perform/1` entry passes `DateTime.utc_now/0`).

  `now` is handed to `Billing.active_trials/1` as well, so the working set and
  the per-row arithmetic are read off ONE instant.
  """
  @spec run(DateTime.t()) :: %{
          noticed_3d: non_neg_integer(),
          noticed_1d: non_neg_integer(),
          expired: non_neg_integer(),
          teardowns: non_neg_integer(),
          finalized: non_neg_integer()
        }
  def run(now) do
    zero = %{noticed_3d: 0, noticed_1d: 0, expired: 0, teardowns: 0, finalized: 0}

    now
    |> Billing.active_trials()
    |> Enum.reduce(zero, fn sub, acc ->
      case Repo.get(Team, sub.team_id) do
        nil -> acc
        team -> handle_trial(acc, team, sub, now)
      end
    end)
  end

  # A trial with no window is malformed — skip it (never entitled anyway).
  # `active_trials/1` already filters these out in SQL; the clause stays as the
  # local statement of the rule, not as the only place it is enforced.
  defp handle_trial(acc, _team, %Subscription{current_period_end: nil}, _now), do: acc

  defp handle_trial(acc, team, %Subscription{current_period_end: ends} = sub, now) do
    if DateTime.compare(ends, now) != :gt do
      # Window closed and this is still a `trial` row (unconverted) → tear down,
      # and finalise the money row once there is nothing left to tear down.
      #
      # The box list is read ONCE, BEFORE the enqueue, and both decisions come
      # off that single read: enqueue a deprovision for every box, and finalise
      # only if there were none. Re-reading after the enqueue would answer the
      # same (an enqueue deletes nothing), but reading twice invites a future
      # edit to finalise a team whose teardown this very pass just started —
      # which is the race the ordering exists to prevent.
      boxes = Registry.list_barkparks(team)
      torn = teardown(boxes)
      f = finalize(sub, boxes, now)
      notify_teardown(team, torn)

      %{
        acc
        | expired: acc.expired + 1,
          teardowns: acc.teardowns + length(torn),
          finalized: acc.finalized + f
      }
    else
      maybe_notice(acc, team, sub, DateTime.diff(ends, now, :second), now)
    end
  end

  # cch-w50 — the terminal write, gated on the teardown having COMPLETED. A team
  # that still has a box keeps its live `trial` row (see handle_trial/4 and the
  # `Billing.expire_trial/2` doc for why that gate is the race guard). Returns
  # how many rows this call finalised: 1 or 0, never a raise — a lost changeset
  # race just means the next hourly pass tries again.
  defp finalize(_sub, [_ | _], _now), do: 0

  defp finalize(sub, [], now) do
    case Billing.expire_trial(sub, now) do
      {:ok, _sub} -> 1
      _ -> 0
    end
  end

  # T-1 supersedes T-3: at <= 1 day we claim+send the 1-day notice AND silently
  # claim the 3-day stamp so a late 3-day email can never fire afterward. The
  # supersede is legitimate ONLY on a run that actually sends the 1-day notice,
  # which is why the mute check gates the whole arm (see `receivable?/1`).
  defp maybe_notice(acc, team, sub, remaining, now) when remaining <= @one_day do
    if receivable?(team) and claim_notice(team.id, :trial_notice_1d_sent_at, now) do
      _ = claim_notice(team.id, :trial_notice_3d_sent_at, now)
      notify(team, sub, notice_days(:one_day))
      %{acc | noticed_1d: acc.noticed_1d + 1}
    else
      acc
    end
  end

  defp maybe_notice(acc, team, sub, remaining, now) when remaining <= @three_days do
    if receivable?(team) and claim_notice(team.id, :trial_notice_3d_sent_at, now) do
      notify(team, sub, notice_days(:three_day))
      %{acc | noticed_3d: acc.noticed_3d + 1}
    else
      acc
    end
  end

  defp maybe_notice(acc, _team, _sub, _remaining, _now), do: acc

  # cch-w52-s2 — READ BEFORE YOU SPEND. Each stamp is not a log line: it is the
  # ENTIRE budget for that warning, claimed by an `UPDATE … WHERE <stamp> IS
  # NULL` that can never match again. Claiming it before knowing whether the
  # alert can even leave the building spends a warning on a notice nobody got,
  # and nothing anywhere reads the stamp back, so no surface can show the loss.
  #
  # The mute arm is the silent one. `Notifications.should_send?/2` returns false
  # for `alerts_enabled: false` BEFORE `dispatch_event/3` can raise, so the
  # crash-rescue's `suppressed` Delivery row (the "Withheld" badge in the
  # console) is never written either: a muted team burned both stamps and left
  # zero rows at any status. Reading the team's settings HERE — through the same
  # public accessor `dispatch_event/3` itself calls first, so the un-muted path
  # sees an identical row and identical ordering — keeps the budget intact
  # across the mute: un-mute and the next hourly run still delivers.
  #
  # This deliberately mirrors ONLY the master switch. `:trial_expiring` is on
  # `@always_send`, so the per-event toggle cannot withhold it, and the crash
  # arm (which DOES leave a row) is not ours to pre-empt.
  defp receivable?(team) do
    Notifications.get_or_create_settings(team).alerts_enabled != false
  end

  # Atomically claim a per-threshold notice stamp: the UPDATE only matches while
  # the stamp is NULL, so exactly one run per threshold wins → the notice sends
  # once. Returns true when this call claimed it.
  defp claim_notice(team_id, field, now) do
    {count, _} =
      from(t in Team, where: t.id == ^team_id and is_nil(field(t, ^field)))
      |> Repo.update_all(set: [{field, now}])

    count == 1
  end

  # One advance-notice alert. Rides the notifications system; `:trial_expiring`
  # is on the always-send allowlist (it still honours a team's global mute).
  #
  # cch-w42-s6: this used to compose the whole sentence here, as `:detail`, and
  # it ended "Upgrade to keep your instance running" — an instruction only the
  # team OWNER can follow, sent to every member, since the alert fan-out has no
  # role predicate (by design: the teardown warning's reach must be maximal).
  # A string authored HERE is authored per-TEAM, before any recipient exists, so
  # no recipient-aware renderer could ever soften it. The payload now carries the
  # FACTS — the day count and the team name — and both renderers compose their own
  # body from them: `EventEmail` per recipient (owner keeps the imperative,
  # everyone else gets the consequence plus who can act) and `Render` for chat,
  # which has built the window from `:days` and prescribed nothing since
  # cch-w32-s1.
  defp notify(team, _sub, days) do
    Notifications.dispatch_event(team, :trial_expiring, %{days: days, name: team.name})
  end

  # Enqueue a deprovision through the EXISTING path for each of the team's boxes.
  # Deduped + idempotent. Takes the ALREADY-READ box list (see handle_trial/4) so
  # the finalisation gate and the enqueue can never disagree about what the team
  # owned this pass.
  #
  # cch-w52-bl: returns the BOXES this pass actually won the enqueue for, not a
  # count. The count is still `length/1` of it, and the identities are what the
  # `:trial_expired` notice needs — a teardown report that cannot name what it
  # tore down leaves the team guessing which of its boxes went.
  defp teardown(boxes) do
    Enum.filter(boxes, fn bp ->
      match?({:ok, _job}, Registry.enqueue_deprovision_job(bp))
    end)
  end

  # cch-w52-bl — THE TEARDOWN'S OWN NOTICE. Fires only on the pass that won the
  # enqueue (see the moduledoc for why that is the exactly-once gate and why a
  # zero-box lapse is deliberately silent).
  #
  # FACTS, NOT A SENTENCE — the same rule cch-w42-s6 imposed on `notify/3` one
  # arm up. The payload carries the instance names and the team name; both
  # renderers compose from them (`EventEmail` per recipient, so the owner gets
  # the imperative and everyone else gets who can act; `Render` for chat), and
  # `Render.teardown_clause/1` is the single formatter both call, so the inbox
  # and Slack can never disagree about which instances a team lost.
  #
  # `dispatch_event/3` never raises into this worker (it rescues into a withhold
  # row), so a notification failure cannot strand a teardown that has already
  # been enqueued.
  defp notify_teardown(_team, []), do: :ok

  defp notify_teardown(team, torn) do
    Notifications.dispatch_event(team, :trial_expired, %{
      name: team.name,
      instances: Enum.map(torn, & &1.name)
    })
  end
end
