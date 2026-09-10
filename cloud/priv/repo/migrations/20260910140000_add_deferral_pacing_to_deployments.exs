defmodule BarkparkCloud.Repo.Migrations.AddDeferralPacingToDeployments do
  @moduledoc """
  deploy-reliability (dr-bl-deferral-scheduled-vs-actual-gap): THE CHAIN'S PACE
  STOPS BEING A SESSION'S SQL.

  ## What a deferral cannot say today

  `Sites.Deploy.defer/3` picks its re-fire window off the backoff ladder
  (`deferral_backoff_seconds/1`) and then throws the number away. The row it
  writes carries `deferral_depth`, `deferral_bound` and `deferral_cause` — the
  chain's SHAPE — and nothing at all about its PACE. So the one question the
  cap experiment turns on cannot be asked of the data:

    * if the gap that actually elapsed ~= the window our own ladder ASKED for,
      the chain is CLOCK-paced and the lever is our own config — in-fence, free;
    * if the actual gap is much LARGER than the scheduled window, the wait is
      real contention on the box and the concurrency experiment earns its time.

  Measured by hand in wave-23 Verify (post-door window from 2026-08-06T22:29:27Z)
  the answer was CLOCK: p50 gap 61.6 s over 2,262 consecutive deferrals, 1,441
  of them inside the 55-75 s band and only 4 below 55 s. That measurement exists
  as a paragraph in a Paper and a SQL statement in a transcript. These two
  columns make it a first-class field a named reader recomputes.

  ## The two columns describe THE SAME INTERVAL

  Both are about the gap that just elapsed — the one between the PREVIOUS
  deferral of this chain and this one — so the ratio is per-row arithmetic and
  never a self-join:

    * `deferral_scheduled_s` — the window the backoff ladder asked for when the
      PREVIOUS round of this chain re-queued its rebuild. It is
      `deferral_backoff_seconds(prior)`, the very expression that round
      evaluated, so scheduled and actual name the same interval.
    * `deferral_actual_gap_s` — how many seconds actually passed:
      `inserted_at(this deferral) - inserted_at(the previous deferral)`.

  ## Why both are NULLABLE and never defaulted, and never backfilled

  Depth 1 has no previous round, so there is NO interval — both columns stay
  NULL, and that is the honest reading, not zero. Every pre-existing row is NULL
  too: the gap for those rows is recoverable only by the same hand SQL this
  change exists to retire, and a backfill would claim the recorder ran when it
  did not. NULL means "not measured"; 0 would mean "measured, and instant".

  ## Why this ALTER is safe on the live table

  Both columns are nullable with NO default, so this is a catalog-only `ALTER`:
  no table rewrite, no per-row work, the ACCESS EXCLUSIVE lock held for a
  catalog update rather than a scan. The same argument
  `20260807150000_add_deferral_structure_to_deployments` and
  `20260910120000_add_grace_counters_to_deployments` made for this table.

  No index. `DeployLedger.DeferralPacing.summarize/1` scans the same pinned
  `inserted_at` window the deploy ledger already scans, and an index with no
  reader is write cost for nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :deferral_scheduled_s, :integer
      add :deferral_actual_gap_s, :integer
    end
  end
end
