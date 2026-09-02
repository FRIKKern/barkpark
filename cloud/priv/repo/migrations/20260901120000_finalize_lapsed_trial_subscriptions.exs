defmodule BarkparkCloud.Repo.Migrations.FinalizeLapsedTrialSubscriptions do
  @moduledoc """
  cch-w50 — THE FIFTEEN GHOST ROWS. The one-shot reconciliation of the trial
  subscriptions that lapsed while nothing was capable of finalising them.

  ## What is on disk (measured read-only on the live control plane, 2026-08-07)

  18 `plan = 'trial'` rows, ALL 18 at `status = 'active'`, of which 15 carry
  `current_period_end < now()` — the earliest lapsed 2026-07-15, three weeks
  before the measurement. All 15 teams have both trial-notice stamps set and
  ZERO rows in `barkparks`: the teardown already ran. The subscription row is
  the only thing left, and it still reads live.

  `TrialExpiryWorker` was structurally incapable of writing it: its expired arm
  enqueued deprovision jobs and touched `subscriptions` with no `Repo.update` /
  `update_all` anywhere in the module, while `Billing.active_trials/0` had no
  period filter and so re-read the same 15 dead rows every hour, 167 completed
  executions deep. The code half of that is fixed in this PR
  (`Billing.expire_trial/2`, called by the worker once the teardown has
  completed). This migration is the DATA half: the fifteen rows that lapsed
  before the writer existed.

  ## The predicate is the worker's own rule, in SQL

  A row is finalised here only if it is exactly what the worker would finalise on
  its next pass:

    * `plan = 'trial'` — never a paid row, never a `forever` comp.
    * `status = 'active'` — a `canceled` or `past_due` row is not ours.
    * `current_period_end IS NOT NULL AND current_period_end < now()` — the
      window has actually closed. A live trial is untouched.
    * NO row in `barkparks` for the team — "the teardown has happened", the same
      gate `TrialExpiryWorker.finalize/3` applies. A lapsed trial whose box is
      still up keeps its live row so a checkout landing in that window still
      takes `activate_from_session/4`'s in-place trial arm (the one that cancels
      the pending deprovision).

  ## Idempotent, by the predicate rather than by a marker

  The `status = 'active'` leg is the idempotence: the up sets `status =
  'canceled'`, so a second run matches ZERO rows and updates nothing. No
  bookkeeping column, no "already ran" flag — running this twice is
  indistinguishable from running it once, and running it after the worker has
  already finalised some rows simply skips those.

  ## `canceled`, not `expired`

  `subscriptions.status` is an app-level enumeration — `active | canceled |
  past_due`, enforced by `Subscription.changeset/2`'s `validate_inclusion`.
  `'expired'` is not a value this schema can hold, and writing it from SQL (which
  the changeset cannot police) would put a value into the column that every
  `status IN (…)` read in `Billing` is blind to. `canceled` is the enumeration's
  existing terminal value, it is what `Billing.cancel_subscription/1` writes, and
  the partial unique index `subscriptions_one_live_per_team_idx` excludes it — so
  a finalised trial never blocks the team's next subscription row.

  ## `canceled_at` is BACKDATED to the window, and that is the down's fence

  These rows went terminal when their window closed, not today. Stamping
  `now()` would claim fifteen teams cancelled on deploy day. So the up writes
  `canceled_at = current_period_end`.

  That also makes the two writers distinguishable, which is what lets the down
  be safe: the WORKER stamps `canceled_at = <the pass that noticed>`, which is
  strictly LATER than `current_period_end` (it only runs once the window has
  closed). So `canceled_at = current_period_end` identifies a row this migration
  wrote and no row the worker wrote, and the down reverses exactly those.

  ## Scale

  Fifteen rows in an 18-row table, one UPDATE with a NOT EXISTS anti-join
  against `barkparks`. No index needed.

  ## Deploy note

  `cloud/**` auto-deploys on merge, so this runs when the lead orders the merge.
  It is safe to run twice and it touches only rows whose boxes are already gone.
  """

  use Ecto.Migration

  def up do
    {sql, params} = up_statement()
    %Postgrex.Result{num_rows: n} = repo().query!(sql, params)

    IO.puts(
      "FinalizeLapsedTrialSubscriptions: finalised #{n} lapsed trial subscription(s) " <>
        "to status='canceled' (canceled_at backdated to current_period_end)."
    )
  end

  def down do
    {sql, params} = down_statement()
    %Postgrex.Result{num_rows: n} = repo().query!(sql, params)

    IO.puts(
      "FinalizeLapsedTrialSubscriptions: reverted #{n} row(s) to status='active' " <>
        "(rows the worker finalised — canceled_at later than the window — are untouched)."
    )
  end

  @doc """
  The up's `{sql, params}` — PUBLIC so the guard test exercises the EXACT
  predicate that ships rather than a paraphrase of it. A predicate change here is
  a predicate change in the test.
  """
  @spec up_statement() :: {String.t(), [term()]}
  def up_statement do
    sql = """
    UPDATE subscriptions AS s
       SET status = 'canceled',
           canceled_at = s.current_period_end,
           updated_at = now()
     WHERE s.plan = 'trial'
       AND s.status = 'active'
       AND s.current_period_end IS NOT NULL
       AND s.current_period_end < now()
       AND NOT EXISTS (
             SELECT 1 FROM barkparks AS b WHERE b.team_id = s.team_id
           )
    """

    {sql, []}
  end

  @doc """
  The reverse, fenced on this migration's own signature: a `trial` row that is
  `canceled` with `canceled_at` EQUAL to `current_period_end`. The worker stamps
  a strictly later `canceled_at`, so its rows are never reverted.

  AND fenced on the unique index. `subscriptions_one_live_per_team_idx` admits
  one `active`/`past_due` row per team; a team that SUBSCRIBED after this
  migration ran now holds a live paid row, and reviving its dead trial alongside
  would violate that index and abort the whole down. The anti-join skips such a
  team — the down is a best-effort undo of rows that can still be undone, never a
  transaction that refuses to run because one team moved on.
  """
  @spec down_statement() :: {String.t(), [term()]}
  def down_statement do
    sql = """
    UPDATE subscriptions AS s
       SET status = 'active',
           canceled_at = NULL,
           updated_at = now()
     WHERE s.plan = 'trial'
       AND s.status = 'canceled'
       AND s.canceled_at IS NOT NULL
       AND s.current_period_end IS NOT NULL
       AND s.canceled_at = s.current_period_end
       AND NOT EXISTS (
             SELECT 1 FROM subscriptions AS live
              WHERE live.team_id = s.team_id
                AND live.id <> s.id
                AND live.status IN ('active', 'past_due')
           )
    """

    {sql, []}
  end
end
