defmodule BarkparkCloud.Repo.Migrations.AddTransitionToPlatformDeliveries do
  @moduledoc """
  deploy-reliability W25 (charter D437): THE CROWN LEARNS TO TELL A ROLLBACK
  FROM A NO-OP — before it holds its first honest row.

  ## The measurement that forces this migration

  Taken on guerrilla's OWN live slot pair on 2026-08-08: green `b97663730` ->
  idle blue `c0e43440b`, a REAL two-commit rollback.

      git rev-list --count green..blue    -> 0
      git rev-list --count --left-right green...blue -> 2  0

  `0` is byte-identical to what a no-op deploy reads. `platform_deliveries` today
  has no column that can hold the difference: a rollback posted through the
  recorder renders as an ordinary delivery of an older sha, and a divergence
  renders as a delivery of one commit. The crown's whole purpose is to be the
  place an operator learns what actually reached the fleet, and on its current
  shape the two worst outcomes are the ones it cannot say.

  ## Why the columns ship BEFORE the writer

  A backfill cannot recover this. `previous_sha` is a fact that exists only at
  the instant of the deploy — what the box was serving before it moved. Once the
  box has moved, nothing on the control plane, in GitHub, or in the row itself
  can reconstruct it, so a row written without these columns is permanently
  unclassifiable. Adding them after real rows exist would produce a table split
  between rows that can be read and rows that can only be guessed at, and the
  guess would land as `forward` — the exact laundering this epic exists to end.

  ## The two columns

    * `previous_sha` — what the box was serving immediately BEFORE this
      delivery. NULLABLE and LOAD-BEARING: NULL means the writer could not
      determine it (a first-ever delivery, a fresh box, a `gc`'d sha, a
      recorder that could not reach the box). Never an empty string, never the
      new sha standing in for the old one.
    * `transition` — the verdict on `previous_sha` -> `sha`:
      `forward` | `rollback` | `diverged` | `noop` | `unknown`. NULL means the
      writer did not attempt a verdict at all, which is distinct from `unknown`
      (it tried and could not decide).

  A `rolled_back` BOOLEAN was considered and REJECTED (D437). Two of the five
  real outcomes are not expressible in a boolean: `diverged` (the two shas share
  no ancestry line — both sides of the range are non-empty) and `unknown` (the
  range could not be computed). A boolean would have to be widened on the first
  divergence, and until then every divergence would record as `false` — a
  confident, wrong "not a rollback".

  ## Why this ALTER is safe on the live table

  Both columns are NULLABLE with NO DEFAULT, so this is a catalog-only update:
  Postgres records the new attributes and does not rewrite a single existing
  row. Precedent in this repo: `20260808050000_add_commit_distance_to_barkparks`
  (same shape, same argument). There is nothing to backfill — a pre-migration
  row is honestly unclassified, and NULL says exactly that.

  NO INDEX. Nothing queries on `transition` yet; an index with no reader is
  write cost bought for nothing, and it can be added by the wave that first
  needs it.

  `cloud/Dockerfile`'s CMD runs migrations when the IDLE slot boots WHILE THE
  OLD SLOT STILL SERVES, so a migration here runs against a schema the currently
  serving release is still reading. Adding two nullable columns is invisible to
  that older release: it selects a fixed column list through Ecto and never sees
  them.

  MIGRATION ORDER: the LEAD orders this one. It assumes no deploy window.
  """

  use Ecto.Migration

  def up do
    alter table(:platform_deliveries) do
      add :previous_sha, :string
      add :transition, :string
    end
  end

  # A real down, not `change` inference: this migration must be reversible by
  # hand on a box mid-incident, and a reader must be able to see exactly what
  # comes off. Dropping two nullable, unindexed, unread columns loses only the
  # classification — the delivery rows themselves survive intact.
  def down do
    alter table(:platform_deliveries) do
      remove :previous_sha
      remove :transition
    end
  end
end
