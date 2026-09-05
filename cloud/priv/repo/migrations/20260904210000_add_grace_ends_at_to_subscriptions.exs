defmodule BarkparkCloud.Repo.Migrations.AddGraceEndsAtToSubscriptions do
  use Ecto.Migration

  @moduledoc """
  cch-w57-bl: `subscriptions.current_period_end` carried THREE clocks in one
  column — the dunning grace anchor (`Billing.mark_past_due/2` wrote
  `now + @grace_days`), the trial expiry (`grant_trial/1` writes 14 days out),
  and — the moment anyone syncs it — Stripe's renewal date. `entitled?/1` and
  `maybe_enforce/1` both branched on exactly that column, so a payload-sourced
  write there could extend a 3-day grace to ~27 days, suspend a paying team's
  boxes in-band, or (on an ABSENT field) write nil and leave an unpaid past_due
  team entitled forever. Wave 57 REFUSED the period-end sync on this ground
  (charter D672) rather than sequencing it; this column is the prerequisite.

  ## The column

  `add :grace_ends_at, :utc_datetime_usec` — NULL-able, NO default, matching the
  `:utc_datetime_usec` type of every other timestamp on the row
  (`current_period_end`, `canceled_at`, `refunded_at`). On PG11+ a NULL-able
  `ADD COLUMN` with no default is catalog-only and rewriteless. NO new index: the
  only readers are `entitled?/1` and `maybe_enforce/1`, both of which already
  hold the `%Subscription{}` struct they are deciding about — nothing queries
  `WHERE grace_ends_at ...`. `current_period_end` KEEPS the trial expiry (and its
  `trial_expiry_horizon` index), which is now its only meaning.

  ## The backfill

      UPDATE subscriptions SET grace_ends_at = current_period_end
       WHERE status = 'past_due' AND grace_ends_at IS NULL

  Scoped to `past_due` because that is the ONLY status for which
  `current_period_end` ever held a grace anchor — on a `trial` row the same
  column holds the trial expiry, and copying THAT into `grace_ends_at` would
  invent a dunning deadline for a team that is not in dunning.

  The backfill is LOAD-BEARING, not cosmetic. The same slice makes a nil
  `grace_ends_at` on a `past_due` row mean NOT entitled (it used to mean "no
  enforcement" — the hazard this row was filed for). Shipping the column without
  the backfill would therefore de-entitle every team currently in dunning at the
  instant the release boots, suspending live boxes for teams whose grace window
  had days left. `grace_ends_at IS NULL` scopes it to rows this migration has not
  already filled, so a re-run is a no-op.

  A `past_due` row whose `current_period_end` was itself NULL stays NULL and IS
  de-entitled — correctly: that is precisely the "unpaid box that never suspends
  and never expires" state, and there is no window to preserve.

  No absolute row count is pinned here: `subscriptions` is a live table and any
  literal would be stale before review.

  ## down/0

  Drops the column. Nothing is lost that `down/0` cannot restore in the sense
  that matters — the pre-migration tree reads `current_period_end` for the grace
  window, and the backfill above only COPIED from it (it never cleared the
  source), so a rollback lands on the same anchors it started with.
  """

  def up do
    alter table(:subscriptions) do
      add :grace_ends_at, :utc_datetime_usec
    end

    # `flush/0` so the UPDATE below sees the column in the same migration.
    flush()

    %Postgrex.Result{num_rows: filled} = repo().query!(backfill_sql(), [])

    IO.puts(
      "AddGraceEndsAtToSubscriptions: carried the grace anchor onto #{filled} past_due " <>
        "subscription row(s); current_period_end now means trial expiry only."
    )
  end

  def down do
    alter table(:subscriptions) do
      remove :grace_ends_at
    end
  end

  @doc """
  The single backfill UPDATE. Public so a guard test can exercise the EXACT
  statement that ships rather than a paraphrase of it.
  """
  @spec backfill_sql() :: String.t()
  def backfill_sql do
    """
    UPDATE subscriptions
       SET grace_ends_at = current_period_end
     WHERE status = 'past_due'
       AND grace_ends_at IS NULL
    """
  end
end
